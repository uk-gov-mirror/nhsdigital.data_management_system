module Import
  module Colorectal
    module Providers
      module Leeds
        # Leeds importer for colorectal (post-2025 format)
        class LeedsHandlerColorectalV2 < Import::Germline::ProviderHandler
          include Import::Helpers::Colorectal::Providers::Rr8::Constants

          def process_fields(record)
            # check if should process record from Other Cancer file
            return unless should_process?(record)

            genocolorectal = Import::Colorectal::Core::Genocolorectal.new(record)
            genocolorectal.add_passthrough_fields(record.mapped_fields,
                                                  record.raw_fields,
                                                  PASS_THROUGH_FIELDS,
                                                  FIELD_NAME_MAPPINGS)

            populate_variables(record)
            process_test_scope(genocolorectal)
            setup_derived_values(record)
            genotypes = []

            if genocolorectal.full_screen?
              add_fs_moleculartestingtype(genocolorectal, record)
              @genes_panel = genes_panel
              res = process_fs_rec(genocolorectal, record, genotypes)
            elsif genocolorectal.targeted?
              add_targ_moleculartestingtype(genocolorectal)
              res = process_targ_rec(genocolorectal, record, genotypes)
            end
            # correcting ebatch provider and registry to RR8 (from RR8_V2_POST2025) to allow
            # data to persist in the database
            @batch.provider = 'RR8'
            @batch.registryid = 'RR8'
            res.each { |cur_genotype| @persister.integrate_and_store(cur_genotype) }
          end

          def should_process?(record)
            file_name = @batch.original_filename
            return true unless file_name =~ /Other/ix

            fields = record.raw_fields
            return false unless fields['moleculartestingtype'] == 'Familial'

            rep_scan  = fields['report']&.scan(MMR_GENE_REGEX)
            diag_scan = fields['diagnosis_report']&.scan(MMR_GENE_REGEX)
            has_genes = rep_scan&.any? || diag_scan&.any?

            return false unless has_genes
            return false if fields['diagnosis_report'] =~ /ataxia/i
            return false if fields['codingdnasequencechange'] =~ /BRCA/i

            true
          end

          def populate_variables(record)
            populate_raw_field_variables(record)
            initialize_processing_variables
          end

          def populate_raw_field_variables(record)
            @report = record.raw_fields['report']
            @moltestingtype = record.raw_fields['moleculartestingtype']
            @value1 = record.raw_fields['proteinimpact']
            @value12 = record.raw_fields['zygosity']
            @report_result = record.raw_fields['genotype']
            @value2 = record.raw_fields['gene']
            @result = record.raw_fields['codingdnasequencechange']
            @diag_report = record.raw_fields['diagnosis_report']
            @comment = record.raw_fields['variantpathclass']
            @test = record.raw_fields['karyotypingmethod']
          end

          def initialize_processing_variables
            @pos_gene          = nil
            @variantpathclass  = nil
            @cdna_mutations    = nil
            @exonic_mutations  = nil
            @zygosity          = nil
          end

          def process_test_scope(genocolorectal)
            if @moltestingtype == 'Familial'
              genocolorectal.add_test_scope(:targeted_mutation)
            else
              genocolorectal.add_test_scope(:full_screen)
            end
          end

          def add_fs_moleculartestingtype(genocolorectal, record)
            indication_catgeory = record.raw_fields['indicationcategory']
            return unless %w[R211 R414].include? indication_catgeory

            genocolorectal.add_molecular_testing_type_strict(:diagnostic)
          end

          def add_targ_moleculartestingtype(genocolorectal)
            if @report_result.match?(/conf/i) || @report_result.match?(/R240/i)
              genocolorectal.add_molecular_testing_type_strict(:diagnostic)
            elsif @report_result.match?(/pred/i) || @report_result.match?(/R242/i)
              genocolorectal.add_molecular_testing_type_strict(:predictive)
            end
          end

          def genes_panel
            genes = []
            genes.concat(extract_genes_from_diagnosis_report)
            genes.concat(extract_genes_from_main_report)
            genes.concat(extract_genes_from_report_results)

            detected_genes = genes.flatten.compact.uniq
            detected_genes.empty? ? default_genes_for_test_type : detected_genes
          end

          def extract_genes_from_diagnosis_report
            diag_report_match = @diag_report&.match(/Genes\sscreened\sin\sthe[^.]*\./im)
            return [] unless diag_report_match

            diag_report_text = diag_report_match[0]
            scanned_genes = diag_report_text.scan(COLORECTAL_GENES_REGEX)
            scanned_genes || []
          end

          def extract_genes_from_main_report
            match = @report&.match(PATIENT_SCREENED_REGEX)
            return [] unless match

            relevant_text = match[1]
            scanned_genes = relevant_text.scan(COLORECTAL_GENES_REGEX)
            scanned_genes || []
          end

          def extract_genes_from_report_results
            result_genes = @report_result&.scan(COLORECTAL_GENES_REGEX)
            result_genes || []
          end

          def default_genes_for_test_type
            case @moltestingtype
            when 'R209.1' # Comprehensive colorectal cancer panel
              %w[APC BMPR1A EPCAM GREM1 MLH1 MSH2 MSH6 MUTYH NTHL1 PMS2 POLD1 POLE PTEN SMAD4 STK11]
            when 'R210.2' # Lynch syndrome focused panel
              %w[MLH1 MSH2 MSH6 PMS2]
            else
              []
            end
          end

          def setup_derived_values(record)
            @zygosity = calc_zygosity
            @variantpathclass = cal_variantpathclass(record)
            setup_mutation_fields
            setup_reference_transcript_id
          end

          def setup_mutation_fields
            @cdna_mutations = extract_cdna_mutations
            @exonic_mutations = extract_exonic_mutations
            @protein_impact = extract_protein_impact
          end

          def extract_cdna_mutations
            @result&.match(CDNA_REGEX) || @value1&.match(CDNA_REGEX)
          end

          def extract_exonic_mutations
            @result&.match(EXON_VARIANT_REGEX) || @value1&.match(EXON_VARIANT_REGEX)
          end

          def extract_protein_impact
            @value1&.match(PROTEIN_REGEX) || @result&.match(PROTEIN_REGEX)
          end

          def setup_reference_transcript_id
            @refid = @result&.match(REF_TRANSCRIPT_ID) || @value1&.match(REF_TRANSCRIPT_ID)
          end

          def process_fs_rec(genocolorectal, record, genotypes)
            # priority based extracting details
            return genotypes if fail_rec?(genocolorectal, genotypes)

            process_result_variant_rec(genocolorectal, record, genotypes)
            process_protein_impact_variant_rec(genocolorectal, record, genotypes)
            return genotypes if gene_variant_rec?(genocolorectal, record, genotypes)
            return genotypes if normal_result_rec?(genocolorectal, genotypes)
            return genotypes if normal_report_result?(genocolorectal, genotypes)

            first_of_report_variant_rec?(genocolorectal, record, genotypes)
          end

          def fail_rec?(genocolorectal, genotypes)
            return false unless @report_result =~ /fail/i && @report_result !~ /dosage/i

            process_status_genes(9, @genes_panel, genocolorectal, genotypes)
            true
          end

          def process_result_variant_rec(genocolorectal, record, genotypes)
            return unless @value2.nil? && (@result =~ CDNA_REGEX || @result =~ EXON_REGEX || @result =~ /heterozygo/i)

            gene = @result&.scan(COLORECTAL_GENES_REGEX)
            @pos_gene = gene.flatten.uniq
            teststatus = case @value1
                         when /C1/, /C2/
                           10
                         else
                           2
                         end
            return if @pos_gene.blank?

            extract_mutations_from_src(@result)
            process_variant_rec(genocolorectal, teststatus, record, genotypes)
          end

          def process_protein_impact_variant_rec(genocolorectal, record, genotypes)
            unless @value2.nil? && (@value1 =~ CDNA_REGEX || @value1 =~ EXON_REGEX || @value1 =~ /\A(?:#{GENES})/i)
              return
            end

            gene = @value1&.scan(COLORECTAL_GENES_REGEX)
            @pos_gene = gene.flatten.uniq
            @pos_gene = ['PMS2'] if @value1 =~ /NM_000535.5/
            return if @pos_gene.blank?

            teststatus = determine_protein_impact_test_status
            extract_mutations_from_src(@value1)
            process_variant_rec(genocolorectal, teststatus, record, genotypes)
          end

          def determine_protein_impact_test_status
            case @value1
            when /C1/, /C2/
              10
            else
              2
            end
          end

          def gene_variant_rec?(genocolorectal, record, genotypes)
            return false if @value2.nil?

            scanned_genes = @value2&.scan(COLORECTAL_GENES_REGEX)
            @pos_gene = scanned_genes&.flatten&.uniq
            @pos_gene -= ['CHEK2'] unless @pos_gene.nil?
            return false if @pos_gene.blank?

            process_variant_rec(genocolorectal, 2, record, genotypes)
            negative_genes = @genes_panel - @pos_gene
            process_status_genes(1, negative_genes, genocolorectal, genotypes)
            true
          end

          def normal_result_rec?(genocolorectal, genotypes)
            return false unless @result =~ /No.*detected/i

            negative_genes = @genes_panel
            process_status_genes(1, negative_genes, genocolorectal, genotypes)
            true
          end

          def normal_report_result?(genocolorectal, genotypes)
            return false unless @report_result =~ /normal/i

            process_status_genes(1, @genes_panel, genocolorectal, genotypes)
            true
          end

          def first_of_report_variant_rec?(genocolorectal, record, genotypes)
            return genotypes unless @report =~ /.*heterozygous\s+for.*pathogenic\s*#{COLORECTAL_GENES_REGEX}/ix

            @pos_gene = [$LAST_MATCH_INFO[:colorectal]]
            if @pos_gene.present?
              extract_mutations_from_src(@report)
              process_variant_rec(genocolorectal, 2, record, genotypes)
              negative_genes = @genes_panel - @pos_gene
              process_status_genes(1, negative_genes, genocolorectal, genotypes)
            end
            genotypes
          end

          def process_variant_rec(genocolorectal, status, _record, genotypes)
            genocolorectal_dup = genocolorectal.dup_colo
            add_geneticinheritance(genocolorectal_dup)
            genocolorectal_dup.add_gene_colorectal(@pos_gene[0])
            genocolorectal_dup.add_zygosity(@zygosity)
            process_cdna_variant(genocolorectal_dup, @cdna_mutations) if @cdna_mutations.present?
            process_protein_impact(genocolorectal_dup, @protein_impact) if @protein_impact.present?
            process_exonic_variant(genocolorectal_dup, @exonic_mutations) if @exonic_mutations.present?
            genocolorectal_dup.add_referencetranscriptid(@refid.to_s) if @refid.present?
            genocolorectal_dup.add_variant_class(@variantpathclass)
            genocolorectal_dup.add_status(status)
            genotypes << genocolorectal_dup
          end

          def process_status_genes(status, negative_genes, genocolorectal, genotypes)
            negative_genes&.each do |gene|
              genocolorectal_dup = genocolorectal.dup_colo
              genocolorectal_dup.add_gene_colorectal(gene)
              genocolorectal_dup.add_status(status)
              genotypes << genocolorectal_dup
            end
          end

          def process_targ_rec(genocolorectal, record, genotypes)
            @pos_gene = []
            return genotypes if zygosity_variant_targ_rec?(genocolorectal, record, genotypes)
            return genotypes if variant_absent_targ_rec?(genocolorectal, genotypes)
            return genotypes if no_result_targ_rec?(genocolorectal, genotypes)
            return genotypes if no_biallelic_targ_rec?(genocolorectal, genotypes)
            return genotypes if cdna_het_variant_targ_rec?(genocolorectal, record, genotypes)
            return genotypes if result_variant_absent_targ_rec?(genocolorectal, genotypes)

            genotypes
          end

          def zygosity_variant_targ_rec?(genotype, record, genotypes)
            return false unless @value12 =~ /heterozyg|homozyg|mosaic/i

            @pos_gene = @value2&.scan(MMR_GENE_REGEX)
            @pos_gene = @pos_gene&.flatten&.uniq || []
            @variantpathclass = cal_variantpathclass_targ
            process_variant_rec(genotype, 2, record, genotypes)
            true
          end

          def variant_absent_targ_rec?(genotype, genotypes)
            return false unless @value12 =~ /variant\sabsent|not\sdetected/i

            negative_gene = @value2&.scan(MMR_GENE_REGEX)
            negative_gene = negative_gene&.flatten&.uniq
            process_status_genes(1, negative_gene, genotype, genotypes)
            true
          end

          def no_result_targ_rec?(genotype, genotypes)
            return false unless @report_result =~ /Fail/i

            targ_gene = find_target_gene_from_sources
            process_failed_target_gene(targ_gene, genotype, genotypes)
            true
          end

          def find_target_gene_from_sources
            [@value2, @test, @diag_report].each do |source|
              result = source&.scan(MMR_GENE_REGEX)
              gene = result&.flatten&.uniq
              return gene if gene&.any?
            end
            nil
          end

          def process_failed_target_gene(targ_gene, genotype, genotypes)
            if targ_gene&.size == 1
              process_status_genes(9, targ_gene, genotype, genotypes)
            else
              genotype_dup = genotype.dup
              genotype_dup.add_status(9)
              genotypes << genotype_dup
            end
          end

          def no_biallelic_targ_rec?(genotype, genotypes)
            return false unless @report =~ /Biallelic.*neg/ix || @result =~ /No\sbiallelic|No\sbi-allelic/ix

            targ_gene = @report&.scan(MMR_GENE_REGEX)
            targ_gene = targ_gene&.flatten&.uniq
            process_status_genes(4, targ_gene, genotype, genotypes)
            true
          end

          def cdna_het_variant_targ_rec?(genotype, record, genotypes)
            return false unless @result =~ CDNA_REGEX || @result =~ EXON_REGEX || @result =~ /het/

            find_genes_from_cdna_sources
            @variantpathclass = classify_first_of_report
            process_variant_rec(genotype, 2, record, genotypes)
            true
          end

          def find_genes_from_cdna_sources
            @pos_gene = []

            [@result, @test, @report_result, @report].each do |src|
              result = src&.scan(MMR_GENE_REGEX)
              flattened_result = result&.flatten&.uniq
              if flattened_result&.any?
                @pos_gene = flattened_result
                break
              end
            end
          end

          def result_variant_absent_targ_rec?(genotype, genotypes)
            return false unless @result =~ /(variant|variaint)\sabsent|no.*detected/ix

            negative_gene = []

            [@result, @report].each do |src|
              result = src&.scan(MMR_GENE_REGEX)
              flattened_result = result&.flatten&.uniq
              if flattened_result&.any?
                negative_gene = flattened_result
                break
              end
            end

            process_status_genes(1, negative_gene, genotype, genotypes)
            true
          end

          def extract_mutations_from_src(src)
            @cdna_mutations = src&.match(CDNA_REGEX)
            @exonic_mutations = src&.match(EXON_VARIANT_REGEX)
            @protein_impact = src&.match(PROTEIN_REGEX)
          end

          def add_geneticinheritance(genocolorectal)
            geneticinheritance = if @value12 =~ /mosaic/i ||
                                    @result =~ /VAF/ || @result =~ /dosage ~0\./
                                   6
                                 else
                                   4
                                 end
            genocolorectal.attribute_map['geneticinheritance'] = geneticinheritance
          end

          def calc_zygosity
            [@value12, @value1, @result].each do |v|
              next unless v

              return 1 if v =~ /het/i
              return 2 if v =~ /homo/i
            end
            nil
          end

          def cal_variantpathclass(_record)
            varclass = classify_variant_pathogenicity
            varclass || classify_protein_impact
          end

          def cal_variantpathclass_targ
            varclass = classify_variant_pathogenicity
            varclass || classify_first_of_report
          end

          def classify_variant_pathogenicity
            case @comment
            when /Likely\spathogenic/i
              4
            when /Pathogenic/i
              5
            when /Uncertain\ssignificance/i
              3
            end
          end

          def classify_protein_impact
            case @value1
            when /C1/
              1
            when /C2/
              2
            when /\(cold\sC3\)/i
              8
            when /\(hot\sC3\)/i
              9
            when /C3/
              3
            end
          end

          def classify_first_of_report
            case @report
            when /Likely\spathogenic/i
              4
            when /Pathogenic/i
              5
            end
          end

          def process_exonic_variant(genotype, mutation)
            return if mutation[:exons].blank?

            genotype.add_exon_location(mutation[:exons])
            genotype.add_variant_type(mutation[:variant])
            @logger.debug "SUCCESSFUL exon variant parse for: #{mutation}"
          end

          def process_cdna_variant(genotype, mutation)
            return if mutation[:cdna].blank?

            genotype.add_gene_location(mutation[:cdna])
            @logger.debug "SUCCESSFUL cdna change parse for: #{mutation}"
          end

          def process_protein_impact(genotype, mutation)
            if mutation[:impact].present?
              genotype.add_protein_impact(mutation[:impact])
              @logger.debug "SUCCESSFUL protein parse for: #{mutation[:impact]}"
            else
              @logger.debug "FAILED protein parse for: #{mutation}"
            end
          end
        end
      end
    end
  end
end
