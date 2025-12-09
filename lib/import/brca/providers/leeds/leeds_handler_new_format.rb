module Import
  module Brca
    module Providers
      module Leeds
        # Process Leeds-specific record details into generalized internal genotype format for > 2025 files
        # rubocop:disable Metrics/ClassLength
        class LeedsHandlerNewFormat < Import::Germline::ProviderHandler
          include Import::Helpers::Brca::Providers::Rr8::Constants

          # rubocop:disable Metrics/MethodLength
          def process_fields(record)
            # check if should process record from Other Cancer file
            return unless should_process?(record)

            genotype = Import::Brca::Core::GenotypeBrca.new(record)
            genotype.add_passthrough_fields(record.mapped_fields, record.raw_fields,
                                            PASS_THROUGH_FIELDS)
            genotype.attribute_map['organisationcode_testresult'] = '699C0'
            populate_variables(record)

            process_test_scope(genotype)
            setup_derived_values(record)
            genotypes = []
            if genotype.full_screen?
              add_fs_moleculartestingtype(genotype, record)
              @genes_panel = get_genes_panel(record)
              res = process_fs_rec(genotype, record, genotypes)
            elsif genotype.targeted?
              add_targ_moleculartestingtype(genotype)
              res = process_targ_rec(genotype, record, genotypes)
            end

            res.each { |cur_genotype| @persister.integrate_and_store(cur_genotype) }
          end
          # rubocop:enable Metrics/MethodLength

          # rubocop:disable Metrics/CyclomaticComplexity
          def should_process?(record)
            file_name = @batch.original_filename
            return true unless file_name =~ /Other/ix

            fields = record.raw_fields
            return false unless fields['moleculartestingtype'] == 'Familial'

            rep_scan  = fields['report']&.scan(NEW_TARG_GENES_REGEX)
            diag_scan = fields['diagnosis_report']&.scan(NEW_TARG_GENES_REGEX)
            has_genes = rep_scan&.any? || diag_scan&.any?

            return false unless has_genes
            return false if fields['diagnosis_report'] =~ /BAP1/i
            return false if fields['codingdnasequencechange'] =~ /MUTYH/i
            return false if fields['genotype'] =~ /prenatal/i

            true
          end
          # rubocop:enable Metrics/CyclomaticComplexity

          # rubocop:disable Metrics/AbcSize
          def populate_variables(record)
            record.raw_fields['gene']&.gsub!('CHEK 2', 'CHEK2')
            @report = record.raw_fields['report']
            @moltestingtype = record.raw_fields['moleculartestingtype']
            @value1 = record.raw_fields['proteinimpact']
            @value12 = record.raw_fields['zygosity']
            @report_result = record.raw_fields['genotype']
            @value2 = record.raw_fields['gene']
            @result = record.raw_fields['codingdnasequencechange']
            @diag_report = record.raw_fields['diagnosis_report']
            @pos_gene          = nil
            @variantpathclass  = nil
            @cdna_mutations    = nil
            @exonic_mutations  = nil
            @zygosity = nil
          end
          # rubocop:enable Metrics/AbcSize

          def process_test_scope(genotype)
            if @moltestingtype == 'Familial'
              genotype.add_test_scope(:targeted_mutation)
            else
              genotype.add_test_scope(:full_screen)
            end
          end

          def add_fs_moleculartestingtype(genotype, record)
            indication_catgeory = record.raw_fields['indicationcategory']
            return unless %w[R207 R444].include? indication_catgeory

            genotype.add_molecular_testing_type_strict(:diagnostic)
          end

          def add_targ_moleculartestingtype(genotype)
            if @report_result.match?(/conf/i) || @report_result.match?(/R240/i)
              genotype.add_molecular_testing_type_strict(:diagnostic)
            elsif @report_result.match?(/pred/i) || @report_result.match?(/R242/i)
              genotype.add_molecular_testing_type_strict(:predictive)
            end
          end

          def get_genes_panel(_record)
            genes = []
            genes << @diag_report&.scan(NEW_FORMAT_GENES)
            genes << @report&.scan(NEW_FORMAT_GENES)
            genes << @moltestingtype&.scan(NEW_FORMAT_GENES)
            genes = genes.compact_blank

            r208_matches = @moltestingtype&.scan(/R208.1/i)
            genes << %w[ATM BRCA1 BRCA2 CHEK2 PALB2] if genes.empty? && r208_matches&.size&.positive?

            genes.flatten.uniq - exclude_genes
          end

          def exclude_genes
            exclude_genes = []
            exclude_genes << @report&.scan(/#{NEW_FORMAT_GENES}\sanalysis\shas\snot\sbeen\sperformed/ix)
            exclude_genes << @report&.scan(/#{NEW_FORMAT_GENES}\stesting\shas\sbeen\sreported\spreviously/ix)
            exclude_genes << @report&.scan(/#{NEW_FORMAT_GENES}[a-zA-Z0-9\s]+Li\sFraumeni\ssyndrome/ix)
            exclude_genes.flatten.uniq
          end

          def process_fs_rec(genotype, record, genotypes)
            process_genotype_priorities(genotype, record, genotypes)
          end

          def process_targ_rec(genotype, record, genotypes)
            @pos_gene = []
            return genotypes if zygosity_variant_targ_rec?(genotype, record, genotypes)
            return genotypes if variant_absent_targ_rec?(genotype, genotypes)
            return genotypes if no_result_targ_rec?(genotype, genotypes)
            return genotypes if no_biallelic_targ_rec?(genotype, genotypes)
            return genotypes if cdna_het_variant_targ_rec?(genotype, record, genotypes)
            return genotypes if report_variant_targ_rec?(genotype, record, genotypes)
            return genotypes if positive_variant_absent_targ_rec?(genotype, genotypes)
            return genotypes if non_positive_variant_absent_targ_rec?(genotype, genotypes)

            genotypes
          end

          def zygosity_variant_targ_rec?(genotype, record, genotypes)
            return false unless @value12 =~ /heterozyg|homozyg/i

            @pos_gene = @value2&.scan(NEW_TARG_GENES_REGEX)
            @pos_gene = @pos_gene&.flatten&.uniq || []
            if @pos_gene.empty?
              @pos_gene = @report&.scan(NEW_TARG_GENES_REGEX)
              @pos_gene = @pos_gene&.flatten&.uniq || []
            end
            process_variant_rec(genotype, 2, record, genotypes)
            true
          end

          def variant_absent_targ_rec?(genotype, genotypes)
            return false unless @value12 =~ /variant\sabsent|not\sdetected/i

            negative_gene = @report&.scan(NEW_TARG_GENES_REGEX)
            negative_gene = negative_gene&.flatten&.uniq
            process_status_genes(1, negative_gene, genotype, genotypes)
            true
          end

          def no_result_targ_rec?(genotype, genotypes)
            return false unless @result =~ /No\sresult/i

            targ_gene = @diag_report&.scan(NEW_TARG_GENES_REGEX)
            targ_gene = targ_gene&.flatten&.uniq
            if targ_gene.size == 1
              process_status_genes(9, targ_gene, genotype, genotypes)
            else
              genotype_dup = genotype.dup
              genotype_dup.add_status(9)
              genotypes << genotype_dup
            end
            true
          end

          def no_biallelic_targ_rec?(genotype, genotypes)
            return false unless @result =~ /No\sbiallelic|No\sbi-allelic/ix

            targ_gene = @report&.scan(NEW_TARG_GENES_REGEX)
            targ_gene = targ_gene&.flatten&.uniq
            process_status_genes(4, targ_gene, genotype, genotypes)
            true
          end

          def cdna_het_variant_targ_rec?(genotype, record, genotypes)
            return false unless @result =~ /c\.|het/ix

            @pos_gene = @result&.scan(NEW_TARG_GENES_REGEX)
            @pos_gene = @pos_gene&.flatten&.uniq || []
            if @pos_gene.empty?
              @pos_gene = @report&.scan(NEW_TARG_GENES_REGEX)
              @pos_gene = @pos_gene&.flatten&.uniq || []
            end
            process_variant_rec(genotype, 2, record, genotypes)
            true
          end

          def report_variant_targ_rec?(genotype, record, genotypes)
            return false unless @report_result =~ /Tumour\sresult\sconf\sseq\s\+ve/ix &&
                                @result =~ /No.*detected/ix

            @pos_gene = @report&.scan(NEW_TARG_GENES_REGEX)
            @pos_gene = @pos_gene&.flatten&.uniq
            @cdna_mutations = @report&.match(CDNA)
            @exonic_mutations = @report&.match(EXON_VARIANT_REGEX)
            if @cdna_mutations || @exonic_mutations
              process_variant_rec(genotype, 2, record, genotypes)
            else
              process_status_genes(1, @pos_gene, genotype, genotypes)
            end
            true
          end

          def positive_variant_absent_targ_rec?(genotype, genotypes)
            return false unless @report_result =~ /pos|\+ve/ix && @result =~ /variant\sabsent/i

            negative_gene = @report&.scan(NEW_TARG_GENES_REGEX)
            negative_gene = negative_gene&.flatten&.uniq
            # only process second gene
            negative_gene = [negative_gene[1]] if negative_gene.size == 2
            process_status_genes(1, negative_gene, genotype, genotypes)
            true
          end

          def non_positive_variant_absent_targ_rec?(genotype, genotypes)
            return false unless @report_result !~ /pos|\+ve/ix &&
                                @result =~ /variant\sabsent|no.*detected/ix

            negative_gene = @report&.scan(NEW_TARG_GENES_REGEX)
            negative_gene = negative_gene&.flatten&.uniq || []
            if negative_gene.empty?
              negative_gene = @report_result&.scan(NEW_TARG_GENES_REGEX)
              negative_gene << malformed_brca_gene
              negative_gene = negative_gene&.flatten&.uniq
            end
            process_status_genes(1, negative_gene, genotype, genotypes)
            true
          end

          private

          def malformed_brca_gene
            return 'BRCA1' if @report_result =~ /\bB1\b/

            'BRCA2' if @report_result =~ /\bB2\b/
          end

          def setup_derived_values(record)
            @zygosity = calc_zygosity
            @variantpathclass = cal_variantpathclass(record)
            @cdna_mutations = @result&.match(CDNA) || @value1&.match(CDNA)
            @exonic_mutations = @result&.match(EXON_VARIANT_REGEX)
            @protein_impact = @value1&.match(PROTEIN_REGEX) || @result&.match(PROTEIN_REGEX)
            @refid = @result&.match(REF_TRANSCRIPT_ID)
          end

          def calc_zygosity
            case @value12
            when /het/i
              1
            when /homo/i
              2
            end
          end

          def process_genotype_priorities(genotype, record, genotypes)
            geno = record.raw_fields['genotype']

            # priority based extracting details
            return genotypes if fail_rec?(geno, genotype, genotypes)
            return genotypes if protein_impact_variant_rec?(genotype, record, genotypes)
            return genotypes if normal_result_rec?(genotype, genotypes)
            return genotypes if gene_variant_rec?(genotype, record, genotypes)
            return genotypes if result_variant_rec?(genotype, record, genotypes)
            return genotypes if normal_report_result?(geno, genotype, genotypes)

            first_of_report_variant_rec?(genotype, record, genotypes)
          end

          def fail_rec?(geno, genotype, genotypes)
            return false unless geno =~ /fail/i && geno !~ /dosage/i

            process_status_genes(9, @genes_panel, genotype, genotypes)
            true
          end

          def protein_impact_variant_rec?(genotype, record, genotypes)
            return false unless @value2.nil? && @value1 =~ CDNA_REGEX

            gene = []
            gene << 'PALB2' if @value1 =~ /ALB2/
            gene << @value1&.scan(NEW_FORMAT_GENES)
            @pos_gene = gene.flatten.uniq
            teststatus = @value1 =~ /C(1|2)/ ? 10 : 2

            process_variant_rec(genotype, teststatus, record, genotypes) if @pos_gene.present?
            negative_genes = @genes_panel - @pos_gene
            process_status_genes(1, negative_genes, genotype, genotypes)
            true
          end

          def normal_result_rec?(genotype, genotypes)
            return false unless @result =~ /No.*detected/i || @result =~ /No result - dosage fail'/i || @result == '-'

            negative_genes = @genes_panel
            process_status_genes(1, negative_genes, genotype, genotypes)
            true
          end

          def gene_variant_rec?(genotype, record, genotypes)
            scanned_genes = @value2&.scan(NEW_FORMAT_GENES)
            @pos_gene = scanned_genes&.flatten&.uniq
            return false if @pos_gene.blank?

            process_variant_rec(genotype, 2, record, genotypes)
            negative_genes = @genes_panel - @pos_gene
            process_status_genes(1, negative_genes, genotype, genotypes)
            true
          end

          def result_variant_rec?(genotype, record, genotypes)
            scanned_result = @result&.scan(NEW_FORMAT_GENES)
            @pos_gene = scanned_result&.flatten&.uniq
            return false if @pos_gene.blank?

            process_variant_rec(genotype, 2, record, genotypes)
            negative_genes = @genes_panel - @pos_gene
            process_status_genes(1, negative_genes, genotype, genotypes)
            true
          end

          def normal_report_result?(geno, genotype, genotypes)
            return false unless geno =~ /normal/i

            process_status_genes(1, @genes_panel, genotype, genotypes)
            true
          end

          def first_of_report_variant_rec?(genotype, record, genotypes)
            return genotypes unless @report =~ /.*heterozygous\s+for.*pathogenic\s*#{NEW_FORMAT_GENES}/ix

            @pos_gene = [$LAST_MATCH_INFO[:gene]]
            if @pos_gene.present?
              process_variant_rec(genotype, 2, record, genotypes)
              negative_genes = @genes_panel - @pos_gene
              process_status_genes(1, negative_genes, genotype, genotypes)
            end
            genotypes
          end

          def process_variant_rec(genotype, status, record, genotypes)
            genotype_dup = genotype.dup
            add_geneticinheritance(genotype_dup, record)
            genotype_dup.add_gene(@pos_gene[0])
            genotype_dup.add_zygosity(@zygosity)
            process_cdna_variant(genotype_dup, @cdna_mutations) if @cdna_mutations.present?
            process_protein_impact(genotype_dup, @protein_impact) if @protein_impact.present?
            process_exonic_variant(genotype_dup, @exonic_mutations) if @exonic_mutations.present?
            genotype_dup.add_referencetranscriptid(@refid.to_s) if @refid.present?
            genotype_dup.add_variant_class(@variantpathclass)
            genotype_dup.add_status(status)
            genotypes << genotype_dup
          end

          def add_geneticinheritance(genotype, _record)
            genotype.attribute_map['geneticinheritance'] = @value12 =~ /mosaic/i || @value1 =~ /VAF/ ? 6 : 4
          end

          def cal_variantpathclass(record)
            variantpathclass = record.raw_fields['variantpathclass']
            varclass = classify_variant_pathogenicity(variantpathclass)
            varclass || classify_protein_impact
          end

          def classify_variant_pathogenicity(variantpathclass)
            case variantpathclass
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

          def process_status_genes(status, negative_genes, genotype, genotypes)
            negative_genes&.each do |gene|
              genotype_dup = genotype.dup
              genotype_dup.add_gene(gene)
              genotype_dup.add_status(status)
              genotypes << genotype_dup
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
        # rubocop:enable Metrics/ClassLength
      end
    end
  end
end
