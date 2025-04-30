module Import
  module Helpers
    module Brca
      module Providers
        module Rth
          module Constants
            TEST_SCOPE_MAP = { 'brca_multiplicom'           => :full_screen,
                               'breast-tp53 panel'          => :full_screen,
                               'breast-uterine-ovary panel' => :full_screen,
                               'targeted'                   => :targeted_mutation }.freeze

            TEST_METHOD_MAP = { 'Sequencing, Next Generation Panel (NGS)' => :ngs,
                                'Sequencing, Dideoxy / Sanger'            => :sanger }.freeze

            PASS_THROUGH_FIELDS = %w[age consultantcode
                                     servicereportidentifier
                                     providercode
                                     authoriseddate
                                     requesteddate
                                     sampletype
                                     referencetranscriptid].freeze

            BRCA_REGEX = /(?<brca>BRCA1|
                                  BRCA2|
                                  BRIP1|
                                  CDK4|
                                  CDKN2A|
                                  CHEK2|
                                  MLH1|
                                  MSH2|
                                  MSH6|
                                  PALB2|
                                  PMS2|
                                  PTEN|
                                  RAD51C|
                                  RAD51D|
                                  STK11|
                                  TP53|
                                  APC|
                                  ATM|
                                  BMPR1A|
                                  CDH1|
                                  EPCAM|
                                  FH|
                                  GREM1|
                                  MUTYH|
                                  NTHL1|
                                  POLD1|
                                  POLE|
                                  RNF43|
                                  SMAD4)/ix

            # TODO: reference the Zgene table once this code is moved to Era.
            GENE_VALUES = [7, 8, 590, 18, 20, 865, 2744, 2804, 2808, 3186, 3394, 62, 3615, 3616, 76, 79, 358,
                           451, 577, 794, 1432, 1590, 1882, 2850, 3108, 3408, 5000, 5019, 72].freeze

            RECORD_EXEMPTIONS = ['c.( 442-127_ 593+118)', 'Deletion of whole PTEN gene', 'whole gene deletion',
                                 'Deletion partial exon 11 and exons 12-15', 'whole gene duplication'].freeze

            PROTEIN_REGEX = /p\.\[?\(?(?<impact>.+)(?:\))|
                             p\.\[(?<impact>[a-z0-9*]+)\]|
                             p\.(?<impact>[a-z]+[0-9]+[a-z]+)/ix

            CDNA_REGEX = /c\.\[?(?<cdna>[0-9-]+.+[a-z]+)\]?/i

            EXON_REGEX = /(?<mutationtype>del|inv|dup).+ion\s[a-z0-9]*\s?exons?\s?(?<exons>[0-9]+(?:-[0-9]+)?)|
                          ex(?:on|ons)?\s?(?<exons>[0-9]+(?:(?:-|\+)[0-9]+)?)\s?(?<mutationtype>del|inv|dup)|
                          exon\s?(?<exons>[0-9]+)\s?-exon\s?(?<otherexon>[0-9]+)\s?(?<mutationtype>del|inv|dup)|
                          (?<mutationtype>del|inv|dup)(.+ion)?\s?ex(on)?\s?(?<exons>[0-9]+(-[0-9]+)?)/ix

            GENOMICCHANGE_REGEX = /Chr(?<chromosome>\d+)(\.hg(?<genome_build>\d+))?:\s?g\.(?<effect>.+)/ix

            FULL_SCREEN_REGEX = /(?<fullscreen>panel|
                                  full\s?screen|
                                  full\sscreem|
                                  full\sgene\sscreen|
                                  brca_multiplicom|
                                  hcs|
                                  brca1|
                                  brca2|
                                  CNV.*only|
                                  CNV.*analysis|
                                  SNV.*ONLY|
                                  Cancer\sGene\sPanel\sAnalysis\sOnly|
                                  SNV\sand\sCNV\sanalysis|
                                  SNV\sand\sCNV|
                                  Whole\sgene\sscreen)/xi

            TARGETED_REGEX = /(?<targeted>targeted|
                                RD\sproband\sconfirmation|
                                HNPCC\sFamilial|
                                c.1100\sonly)/xi

            VAR_PATH_CLASS_MAP = {
              'c3' => 3,
              'c4' => 4,
              'c5' => 5,
              '10' => 'invalidvariantpathclass',
              'n/a' => 'invalidvariantpathclass'
            }.freeze

            BRCA_PROFILE = [
              'r207_ovarian',
              'r208_breast',
              'r208+213_breast+pten',
              'r208+216_breast+tp53',
              'r207_chcs_ovarian',
              'r208_chcs_breast',
              'r208+216_chcs_breast+tp53',
              'r208+213_chcs_breast+pten',
              'r430_chcs_ prostate',
              'r444.1_chcs_breast',
              'r444.2_chcs_prostate',
              'familial - brca',
              'r208, r213, r216'
            ].freeze

            BRCA_PROFILE_PHENO = [
              'familial',
              'cancer gene panel analysis only',
              'r0_chcs_custom',
              'cancer mlpa familial',
              'ngs analysis only',
              'familial - cancer ngs'
            ].freeze

            ONLY_BRCA_GENES_REGEX = /(?<brca>BRCA1|BRCA2|BRIP1|PALB2|
                                      RAD51D|RAD51C|CHEK2|ATM)/ix
          end
        end
      end
    end
  end
end
