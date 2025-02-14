require 'possibly'

module Import
  module Colorectal
    module Providers
      module Newcastle
        # Process Newcastle-specific record details into generalized internal genotype format
        class NewcastleHandlerColorectal < Import::Germline::ProviderHandler
          include Import::Helpers::Colorectal::Providers::Rtd::RtdConstants

          def process_fields(record)
            # return for brca cases
            return if record.raw_fields['investigation code'].match(/BRCA/i)

            record.raw_fields['genotype']&.gsub!('SGC5', 'SCG5')
            genocolorectal = Import::Colorectal::Core::Genocolorectal.new(record)
            genocolorectal.add_passthrough_fields(record.mapped_fields,
                                                  record.raw_fields,
                                                  PASS_THROUGH_FIELDS_COLO,
                                                  FIELD_NAME_MAPPINGS_COLO)
            identifier = record.raw_fields['ngs sample number']
            genocolorectal.add_servicereportidentifier(identifier) unless identifier.nil?
            add_organisationcode_testresult(genocolorectal)
            add_test_scope(genocolorectal, record)
            add_test_type(genocolorectal, record)
            add_test_status(genocolorectal, record)
            res = process_variant_records(genocolorectal, record)
            res.each { |cur_genotype| @persister.integrate_and_store(cur_genotype) }
          end

          def add_organisationcode_testresult(genocolorectal)
            genocolorectal.attribute_map['organisationcode_testresult'] = '699A0'
          end

          def add_test_scope(genocolorectal, record)
            moleculartestingtype = record.raw_fields['moleculartestingtype']&.downcase&.strip
            service_category = record.raw_fields['service category']&.downcase&.strip
            investigationcode = record.raw_fields['investigation code']&.downcase&.strip

            if %w[o c 0 a2].include?(service_category)
              add_scope_from_service_category(service_category, genocolorectal)
              @logger.debug 'ADDED SCOPE SERVICE CATEGORY'
            else
              add_scope_from_inv_code_mol_type(investigationcode, moleculartestingtype,
                                               genocolorectal)
            end

            return if genocolorectal.attribute_map['genetictestscope'].present?

            genocolorectal.add_test_scope(:no_genetictestscope)
          end

          def add_scope_from_service_category(service_category, genocolorectal)
            if %w[o c 0].include? service_category
              @logger.debug 'Found O/C/0'
              genocolorectal.add_test_scope(:full_screen)
            elsif service_category == 'a2'
              @logger.debug 'Found A2'
              genocolorectal.add_test_scope(:targeted_mutation)
            end
          end

          def add_scope_from_inv_code_mol_type(inv_code, mol_type, genocolorectal)
            scope = if inv_code == 'hnpcc_pred'
                      :targeted_mutation
                    else
                      TEST_SCOPE_FROM_TYPE_MAP_COLO[mol_type]
                    end
            scope = :no_genetictestscope if scope.blank?
            genocolorectal.add_test_scope(scope)
            @logger.info 'ADDED SCOPE FROM INVESTIGATION CODE/MOLECULAR TESTING TYPE'
          end

          def add_test_type(genocolorectal, record)
            # cludge to handle their change in field mapping...
            reason = record.raw_fields['referral reason']
            unless reason.nil?
              genocolorectal.add_molecular_testing_type_strict(
                TEST_TYPE_MAP_COLO[reason.downcase.strip]
              )
            end
            mtype = record.raw_fields['moleculartestingtype']
            return if mtype.nil?

            genocolorectal.add_molecular_testing_type_strict(
              TEST_TYPE_MAP_COLO[mtype.downcase.strip]
            )
          end

          def add_variant_class(genocolorectal, record)
            variantclass = Maybe(record.mapped_fields['variantpathclass']).
                           or_else(Maybe(record.raw_fields['variant type']))
            genocolorectal.add_variant_class(variantclass)
          end

          def add_test_status(genocolorectal, record)
            gene = record.raw_fields['gene']
            variant = record.raw_fields['genotype']
            teststatus = record.raw_fields['teststatus']
            if gene.present? && variant.present? && pathogenic?(record)
              genocolorectal.add_status(2)
            elsif gene.present? && variant.present? && non_pathogenic?(record)
              genocolorectal.add_status(10)
            elsif gene.present? && variant.blank?
              genocolorectal.add_status(4)
            elsif teststatus.present? && teststatus.scan(/fail/i).size.positive?
              genocolorectal.add_status(9)
            else
              genocolorectal.add_status(1)
            end
          end

          def process_variant_records(genocolorectal, record)
            genocolorectals = []
            if full_screen?(genocolorectal)
              investigation_code = record.raw_fields['investigation code']&.downcase&.strip
              @genes_panel = INVESTIGATION_CODE_GENE_MAPPING[investigation_code]
              process_fullscreen_records(genocolorectal, record, genocolorectals)
            elsif targeted?(genocolorectal) || no_scope?(genocolorectal)
              process_targeted_screen(genocolorectal, record, genocolorectals)
            end
            genocolorectals
          end

          def process_fullscreen_records(genocolorectal, record, genocolorectals)
            variant = record.raw_fields['genotype']
            gene = get_gene(record)
            genocolorectal.add_gene_colorectal(gene)
            if positive_rec?(genocolorectal)
              add_fs_negative_genes(gene, genocolorectal, genocolorectals, record)
              process_variants(genocolorectals, genocolorectal, variant)
            elsif gene.present? # for other status records
              add_fs_negative_genes(gene, genocolorectal, genocolorectals, record)
              genocolorectals.append(genocolorectal)
            else # for other status null gene record
              process_null_gene_rec(genocolorectal, genocolorectals)
            end
            add_variant_class(genocolorectal, record)
          end

          def add_fs_negative_genes(gene, genocolorectal, genocolorectals, record)
            negative_genes = @genes_panel - [gene] unless @genes_panel == [gene]
            variant_gene = record.raw_fields['genotype']&.scan(COLORECTAL_GENES_REGEX)&.flatten
            negative_genes -= variant_gene if variant_gene.present?
            negative_genes&.each do |neg_gene|
              genocolo_other = genocolorectal.dup_colo
              genocolo_other.add_status(1)
              genocolo_other.add_gene_colorectal(neg_gene)
              genocolorectals.append(genocolo_other)
            end
          end

          def process_null_gene_rec(genocolorectal, genocolorectals)
            @genes_panel&.each do |gene|
              genocolorectal_dup = genocolorectal.dup_colo
              genocolorectal_dup.add_gene_colorectal(gene)
              genocolorectals.append(genocolorectal_dup)
            end
          end

          def positive_rec?(genocolorectal)
            genocolorectal.attribute_map['teststatus'] == 2
          end

          def process_targeted_screen(genocolorectal, record, genocolorectals)
            variant = record.raw_fields['genotype']
            gene = get_gene(record)
            genocolorectal.add_gene_colorectal(gene)
            add_variant_class(genocolorectal, record)
            if positive_rec?(genocolorectal)
              process_variants(genocolorectals, genocolorectal, variant)
            else
              genocolorectals.append(genocolorectal)
            end
          end

          def get_gene(record)
            gene = record.raw_fields['gene']
            positive_genes = gene.nil? ? [] : gene.scan(COLORECTAL_GENES_REGEX).flatten.uniq
            if positive_genes.empty?
              positive_genes = record.raw_fields['investigation code'].
                               scan(COLORECTAL_GENES_REGEX).flatten.uniq
            end
            positive_genes[0] unless positive_genes.nil?
          end

          def full_screen?(genocolorectal)
            return false if genocolorectal.attribute_map['genetictestscope'].nil?

            genocolorectal.attribute_map['genetictestscope'].scan(/Full screen/i).size.positive?
          end

          def targeted?(genocolorectal)
            return false if genocolorectal.attribute_map['genetictestscope'].nil?

            genocolorectal.attribute_map['genetictestscope'].scan(/Targeted/i).size.positive?
          end

          def no_scope?(genocolorectal)
            return false if genocolorectal.attribute_map['genetictestscope'].nil?

            genocolorectal.attribute_map['genetictestscope'].scan(/Unable/i).size.positive?
          end

          def pathogenic?(record)
            varpathclass = record.raw_fields['variantpathclass']&.downcase
            if (NON_PATHEGENIC_CODES.exclude? varpathclass) \
              && (NO_MUTATION_DETECTED_CODES.exclude? varpathclass)
              true
            end
          end

          def non_pathogenic?(record)
            varpathclass = record.raw_fields['variantpathclass']&.downcase
            return true if NON_PATHEGENIC_CODES.include? varpathclass

            false
          end

          def process_variants(genocolorectals, genocolorectal, variant)
            genes = variant&.scan(COLORECTAL_GENES_REGEX)&.flatten

            # For variant like "het dup GREM1 and SGC5"
            if genes.present? && genes.all? { |gene| %w[GREM1 SCG5].include?(gene) } && variant.scan(/dup/i).size == 1
              prepare_grem1_scg5_genos(genocolorectals, genocolorectal, variant)
            elsif genes.size > 1
              process_multi_genes(genocolorectals, genocolorectal, variant, genes)
            else
              process_mutations(genocolorectal, variant)
              genocolorectals.append(genocolorectal)
            end
            genocolorectals
          end

          def prepare_grem1_scg5_genos(genocolorectals, genocolorectal, variant)
            varianttype = variant.scan(VARIANTTYPE_REGEX)
            genocolorectal_dup = genocolorectal.dup_colo
            genocolorectal_dup.add_gene_colorectal('GREM1')
            genocolorectal_dup.attribute_map['variantlocation'] = 5
            genocolorectal_dup.add_variant_type(varianttype.join)
            genocolorectals.append(genocolorectal_dup)
            genocolorectal_dup = genocolorectal.dup_colo
            genocolorectal_dup.add_gene_colorectal('SCG5')
            genocolorectal_dup.add_variant_type(varianttype.join)
            genocolorectals.append(genocolorectal_dup)
          end

          def process_multi_genes(genocolorectals, genocolorectal, variant, genes)
            variant_strings = variant.split(genes[-1])
            variant_strings << '' if variant_strings.size == 1
            variant_strings[1].prepend(genes[-1])
            variant_type = variant.scan(VARIANTTYPE_REGEX)
            genocolorectal.add_variant_type(variant_type.join) unless genes.size == variant_type.size
            process_variant_strings(genocolorectals, genocolorectal, variant_strings)
          end

          def process_variant_strings(genocolorectals, genocolorectal, variant_strings)
            variant_strings.each do |variant_str|
              genocolorectal_dup = genocolorectal.dup_colo
              variant_str.scan(COLORECTAL_GENES_REGEX)
              genocolorectal_dup.add_gene_colorectal($LAST_MATCH_INFO[:colorectal])
              process_mutations(genocolorectal_dup, variant_str)
              varianttype = variant_str.scan(VARIANTTYPE_REGEX)
              if genocolorectal_dup.attribute_map['sequencevarianttype'].nil?
                genocolorectal_dup.add_variant_type(varianttype.join)
              end
              genocolorectals.append(genocolorectal_dup)
            end
          end

          def process_mutations(genocolorectal, variant)
            process_cdna_variant(genocolorectal, variant)
            process_exonic_variant(genocolorectal, variant)
            process_protein_impact(genocolorectal, variant)
          end

          def process_exonic_variant(genocolorectal, variant)
            return unless variant.scan(EXON_REGEX).size.positive?

            genocolorectal.add_exon_location($LAST_MATCH_INFO[:exons])
            genocolorectal.add_variant_type($LAST_MATCH_INFO[:variant])
            @logger.debug "SUCCESSFUL exon variant parse for: #{variant}"
          end

          def process_cdna_variant(genocolorectal, variant)
            return unless variant.scan(CDNA_REGEX).size.positive?

            genocolorectal.add_gene_location($LAST_MATCH_INFO[:cdna])
            @logger.debug "SUCCESSFUL cdna change parse for: #{$LAST_MATCH_INFO[:cdna]}"
          end

          def process_protein_impact(genocolorectal, variant)
            if variant.scan(PROTEIN_REGEX).size.positive?
              genocolorectal.add_protein_impact($LAST_MATCH_INFO[:impact])
              @logger.debug "SUCCESSFUL protein parse for: #{$LAST_MATCH_INFO[:impact]}"
            else
              @logger.debug "FAILED protein parse for: #{variant}"
            end
          end
        end
      end
    end
  end
end
