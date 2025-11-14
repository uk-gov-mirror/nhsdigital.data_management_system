require 'test_helper'

class LeedsHandlerNewFormatTest < ActiveSupport::TestCase
  def setup
    @record   = build_raw_record('pseudo_id1' => 'bob')
    @genotype = Import::Brca::Core::GenotypeBrca.new(@record)
    @importer_stdout, @importer_stderr = capture_io do
      @handler = Import::Brca::Providers::Leeds::LeedsHandlerNewFormat.new(EBatch.new)
    end
    @logger = Import::Log.get_logger
  end

  test 'process_failed_test_record' do
    failed_record = build_raw_record('pseudo_id1' => 'patient1')
    failed_record.raw_fields['genotype'] = 'R208_fail_FFPE'
    failed_record.raw_fields['report'] = 'RESULT: No results were obtained for this sample.'

    res = @handler.process_fields(failed_record)
    assert_equal 1, res.size
    res.each do |genotype|
      assert_equal 9, genotype.attribute_map['teststatus']
    end
  end

  test 'process_normal_result_record' do
    res = @handler.process_fields(@record)
    assert_equal 1, res.size
    assert_equal 1, res[0].attribute_map['teststatus'] # normal
    assert_equal 3186, res[0].attribute_map['gene'] # PALB2
  end

  test 'process_variant_rec' do
    variant_record = build_raw_record('pseudo_id1' => 'patient2')
    variant_record.raw_fields['gene'] = nil
    variant_record.raw_fields['codingdnasequencechange'] = 'No pathogenic variants detected'
    variant_record.raw_fields['proteinimpact'] = 'BRCA2 c.2698A>G het (C2)'
    variant_record.raw_fields['zygosity'] = nil
    variant_record.raw_fields['variantpathclass'] = nil
    variant_record.raw_fields['report'] = 'This patient has been screened for variants in the following cancer predisposing genes by sequence and dosage analysis:"\
    "   \n\n\n\nBRCA1, BRCA2, BRIP1, MLH1, MSH2, MSH6, PALB2, RAD51C, RAD51D.\n\n\n\nNo pathogenic variant was identified'

    res = @handler.process_fields(variant_record)
    assert_equal 9, res.size
    variant_genotype = res.find { |g| g.attribute_map['gene'] == 8 } # BRCA2
    assert_equal 10, variant_genotype.attribute_map['teststatus']
    assert_equal 'c.2698A>G', variant_genotype.attribute_map['codingdnasequencechange']
    assert_nil variant_genotype.attribute_map['proteinimpact']
    assert_equal 2, variant_genotype.attribute_map['variantpathclass']
    assert_equal 4, variant_genotype.attribute_map['geneticinheritance']

    res.each do |genotype|
      next if genotype.attribute_map['gene'] == 8

      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'process_multi_gene_panel_r208.1' do
    panel_record = build_raw_record('pseudo_id1' => 'patient3')
    panel_record.raw_fields['moleculartestingtype'] = 'R208.1'
    panel_record.raw_fields['report'] = 'Results are normal'
    panel_record.raw_fields['diagnosis_report'] = 'No variant found'

    res = @handler.process_fields(panel_record)

    # Should have all genes from R208.1 panel
    expected_genes = %w[ATM BRCA1 BRCA2 CHEK2 PALB2]
    assert_equal expected_genes.size, res.size
    assert_equal 451, res[0].attribute_map['gene'] # ATM
    assert_equal 7, res[1].attribute_map['gene'] # BRCA1
    assert_equal 8, res[2].attribute_map['gene'] # BRCA2
    assert_equal 865, res[3].attribute_map['gene'] # CHEK2
    assert_equal 3186, res[4].attribute_map['gene'] # PALB2
  end

  test 'process_gene_variant_rec' do
    gene_variant_rec = build_raw_record('pseudo_id1' => 'patient4')
    gene_variant_rec.raw_fields['gene'] = 'ATM'
    gene_variant_rec.raw_fields['codingdnasequencechange'] = 'c.8156del'
    gene_variant_rec.raw_fields['proteinimpact'] = 'p.(Arg2719fs)'
    gene_variant_rec.raw_fields['zygosity'] = 'Mosaic'
    gene_variant_rec.raw_fields['variantpathclass'] = 'Likely pathogenic'
    gene_variant_rec.raw_fields['report'] = 'This patient has been screened for variants in the ' \
                                            'following cancer predisposing genes by sequence and dosage analysis:   \n\nATM*, BRCA1, BRCA2, ' \
                                            'BRIP1, CHEK2*, MLH1, MSH2, MSH6, PALB2, RAD51C, RAD51D.\n\n\n\nThe likely pathogenic ' \
                                            'ATM variant c.8156del p.(Arg2719fs)'

    res = @handler.process_fields(gene_variant_rec)
    assert_equal 11, res.size

    variant_genotype = res.find { |g| g.attribute_map['gene'] == 451 } # ATM
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal 'c.8156del', variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 'p.Arg2719fs', variant_genotype.attribute_map['proteinimpact']
    assert_equal 4, variant_genotype.attribute_map['variantpathclass']
    assert_equal 6, variant_genotype.attribute_map['geneticinheritance']

    res.each do |genotype|
      next if genotype.attribute_map['gene'] == 451

      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'process_result_variant_rec' do
    result_variant_rec = build_raw_record('pseudo_id1' => 'patient4')
    result_variant_rec.raw_fields['moleculartestingtype'] = 'R208.1'
    result_variant_rec.raw_fields['genotype'] = 'No report required'
    result_variant_rec.raw_fields['gene'] = nil
    result_variant_rec.raw_fields['codingdnasequencechange'] = 'BRCA1 c.4065_4068del heterozygote'
    result_variant_rec.raw_fields['proteinimpact'] = nil
    result_variant_rec.raw_fields['zygosity'] = nil
    result_variant_rec.raw_fields['variantpathclass'] = nil
    result_variant_rec.raw_fields['report'] = 'Reason:Reported under a different indication.'

    res = @handler.process_fields(result_variant_rec)
    assert_equal 2, res.size
    variant_genotype = res[0]
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal 7, variant_genotype.attribute_map['gene']
    assert_equal 'c.4065_4068del', variant_genotype.attribute_map['codingdnasequencechange']
    assert_nil variant_genotype.attribute_map['proteinimpact']
    assert_nil variant_genotype.attribute_map['variantpathclass']
    assert_equal 4, variant_genotype.attribute_map['geneticinheritance']

    normal_genotype = res[1]
    assert_equal 1, normal_genotype.attribute_map['teststatus']
    assert_equal 3186, normal_genotype.attribute_map['gene']
    assert_nil normal_genotype.attribute_map['codingdnasequencechange']
    assert_nil normal_genotype.attribute_map['proteinimpact']
    assert_nil normal_genotype.attribute_map['variantpathclass']
    assert_nil normal_genotype.attribute_map['geneticinheritance']
  end

  test 'normal_report_result_rec' do
    normal_report_result_rec = build_raw_record('pseudo_id1' => 'patient5')
    normal_report_result_rec.raw_fields['genotype'] = 'R208_normal_Apr22'
    normal_report_result_rec.raw_fields['gene'] = nil
    normal_report_result_rec.raw_fields['codingdnasequencechange'] = 'No result'
    normal_report_result_rec.raw_fields['proteinimpact'] = nil
    normal_report_result_rec.raw_fields['diagnosis_report'] = '1. Genes screened in the panel: BRCA1, BRCA2, BRIP1, MLH1, MSH2, MSH6, PALB2, RAD51C, RAD51D ' \
                                                              '(all coding exons and exon-intron boundaries).'

    res = @handler.process_fields(normal_report_result_rec)
    assert_equal 9, res.size
    res.each do |genotype|
      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'first_of_report_variant_rec' do
    first_of_report_variant_rec = build_raw_record('pseudo_id1' => 'patient6')
    first_of_report_variant_rec.raw_fields['genotype'] = 'R208_ATM/CHEK2_C4/5_Apr22'
    first_of_report_variant_rec.raw_fields['gene'] = nil
    first_of_report_variant_rec.raw_fields['codingdnasequencechange'] = nil
    first_of_report_variant_rec.raw_fields['proteinimpact'] = nil
    first_of_report_variant_rec.raw_fields['report'] = 'RESULT: This individual is heterozygous for a germline pathogenic ATM truncating variant (details below). Heterozygous ATM pathogenic variants cause moderate risk1 cancer susceptibility, particularly breast cancer in females (OMIM: 607585; 114480).
IMPLICATIONS : Each of their offspring would be at 50% risk of inheriting this variant and genetic predisposition to ATM-associated cancers. Other relatives are also at increased risk.'
    res = @handler.process_fields(first_of_report_variant_rec)
    assert_equal 2, res.size
    assert_equal 451, res[0].attribute_map['gene']
    assert_equal 2, res[0].attribute_map['teststatus']

    assert_equal 3186, res[1].attribute_map['gene']
    assert_equal 1, res[1].attribute_map['teststatus']
  end

  test 'process_exonic_deletion_variant' do
    exon_record = build_raw_record('pseudo_id1' => 'patient6')
    exon_record.raw_fields['indicationcategory'] = 'R207'
    exon_record.raw_fields['moleculartestingtype'] = 'R207.1'
    exon_record.raw_fields['genotype'] = 'R207 - BRCA Diag C4/5'
    exon_record.raw_fields['gene'] = 'BRCA1'
    exon_record.raw_fields['codingdnasequencechange'] = 'Deletion of exons 1-23'
    exon_record.raw_fields['zygosity'] = 'Heterozygous'
    exon_record.raw_fields['variantpathclass'] = 'Pathogenic'
    exon_record.raw_fields['report'] = 'RESULT: This individual is heterozygous for a germline pathogenic BRCA1 copy number variant (details below).'
    exon_record.raw_fields['diagnosis_report'] = '1.Genes screened in R207 panel: BRCA1, BRCA2, BRIP1, MLH1, MSH2, MSH6, PALB2, RAD51C, RAD51D (all coding exons and exon-intron boundaries).'
    res = @handler.process_fields(exon_record)

    assert_equal 9, res.size

    variant_genotype = res.find { |g| g.attribute_map['gene'] == 7 } # BRCA1
    assert_not_nil variant_genotype
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal '1-23', variant_genotype.attribute_map['exonintroncodonnumber']
    assert_equal 3, variant_genotype.attribute_map['sequencevarianttype']
    assert_equal 5, variant_genotype.attribute_map['variantpathclass']
    assert_equal 1, variant_genotype.attribute_map['variantgenotype']
    assert_equal 4, variant_genotype.attribute_map['geneticinheritance']
    assert_nil variant_genotype.attribute_map['codingdnasequencechange']

    res.each do |genotype|
      next if genotype.attribute_map['gene'] == 7

      assert_equal 1, genotype.attribute_map['teststatus']
      assert_nil genotype.attribute_map['codingdnasequencechange']
      assert_nil genotype.attribute_map['proteinimpact']
      assert_nil genotype.attribute_map['variantpathclass']
      assert_nil genotype.attribute_map['geneticinheritance']
    end
  end

  test 'exclude_genes_functionality' do
    # Test analysis not performed exclusion
    @handler.instance_variable_set(:@report, 'TP53 analysis has not been performed')
    excluded1 = @handler.exclude_genes
    assert_includes excluded1, 'TP53'

    # Test testing reported previously exclusion
    @handler.instance_variable_set(:@report, 'TP53 testing has been reported previously')
    excluded2 = @handler.exclude_genes
    assert_includes excluded2, 'TP53'

    # Test Li Fraumeni syndrome exclusion
    @handler.instance_variable_set(:@report, 'TP53 gene analysis for Li Fraumeni syndrome has been carried out')
    excluded3 = @handler.exclude_genes
    assert_includes excluded3, 'TP53'
  end

  # Targeted testing (Familial) tests
  test 'process_targeted_heterozygous_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ1')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['gene'] = 'BRCA1'
    targeted_record.raw_fields['codingdnasequencechange'] = 'c.5266dup'
    targeted_record.raw_fields['proteinimpact'] = 'p.(Gln1756fs)'
    targeted_record.raw_fields['zygosity'] = 'Heterozygous'
    targeted_record.raw_fields['variantpathclass'] = 'Pathogenic'
    targeted_record.raw_fields['genotype'] = 'R242_pos_MLPA'
    targeted_record.raw_fields['report'] = 'Testing for the familial BRCA1 variant c.5266dup.'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    variant_genotype = res[0]
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal 7, variant_genotype.attribute_map['gene'] # BRCA1
    assert_equal 'c.5266dup', variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 'p.Gln1756fs', variant_genotype.attribute_map['proteinimpact']
    assert_equal 5, variant_genotype.attribute_map['variantpathclass']
    assert_equal 1, variant_genotype.attribute_map['variantgenotype']
  end

  test 'process_targeted_homozygous_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ2')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['gene'] = 'BRCA2'
    targeted_record.raw_fields['codingdnasequencechange'] = 'NM_007294.3:Exon 13 duplication'
    targeted_record.raw_fields['zygosity'] = 'Homozygous'
    targeted_record.raw_fields['variantpathclass'] = 'Pathogenic'
    targeted_record.raw_fields['genotype'] = 'Familial_conf_seq_+ve_R240'
    targeted_record.raw_fields['report'] = 'This individual is heterozygous for the germline familial pathogenic.'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    variant_genotype = res[0]
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal 8, variant_genotype.attribute_map['gene']
    assert_equal 2, variant_genotype.attribute_map['variantgenotype']
    assert_equal 1, variant_genotype.attribute_map['moleculartestingtype']
    assert_equal 'NM_007294.3', variant_genotype.attribute_map['referencetranscriptid']
    assert_equal '13', variant_genotype.attribute_map['exonintroncodonnumber']
    assert_equal 4, variant_genotype.attribute_map['sequencevarianttype']
  end

  test 'process_targeted_variant_absent' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ3')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'NM_007294.3:Exon 13 duplication'
    targeted_record.raw_fields['zygosity'] = 'Variant absent'
    targeted_record.raw_fields['genotype'] = 'Familial testing negative'
    targeted_record.raw_fields['report'] = 'Dosage analysis has shown no evidence of the familial pathogenic BRCA1 variant'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    negative_genotype = res[0]
    assert_equal 1, negative_genotype.attribute_map['teststatus']
    assert_equal 7, negative_genotype.attribute_map['gene'] # BRCA1
  end

  test 'process_targeted_no_result' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ4')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No result'
    targeted_record.raw_fields['genotype'] = 'Fail/Results not required'
    targeted_record.raw_fields['diagnosis_report'] = 'Germline pathogenic variants in CHEK2 have been reported in several studies'
    targeted_record.raw_fields['report'] = 'No results were obtained from this sample despite repeated attempts.'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 9, genotype.attribute_map['teststatus']
    assert_equal 865, genotype.attribute_map['gene'] # BRCA1
  end

  test 'process_targeted_no_result_multiple_genes' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ5')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No result'
    targeted_record.raw_fields['genotype'] = 'Familial testing'
    targeted_record.raw_fields['diagnosis_report'] = 'Testing for BRCA1 and BRCA2 variants'
    targeted_record.raw_fields['report'] = 'Unable to complete testing'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 9, genotype.attribute_map['teststatus']
    assert_nil genotype.attribute_map['gene']
  end

  test 'process_targeted_no_biallelic' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ6')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No bi-allelic inheritance of familial PALB2 variants'
    targeted_record.raw_fields['genotype'] = 'FA familial C5 normal'
    targeted_record.raw_fields['report'] = 'Sequence analysis indicates the absence of bi-allelic inheritance of the familial PALB2 variants'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 4, genotype.attribute_map['teststatus']
    assert_equal 3186, genotype.attribute_map['gene'] # PALB2
  end

  test 'process_targeted_cdna_het_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ7')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'BRCA1 exon 1 deletion heterozygote'
    targeted_record.raw_fields['genotype'] = 'BRCA - Pred B1 C4/C5 MLPA pos'
    targeted_record.raw_fields['report'] = 'This patient is heterozygous for the familial likely pathogenic deletion of BRCA1 exons 1A and 1B'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 7, genotype.attribute_map['gene'] # BRCA1
    assert_equal '1', genotype.attribute_map['exonintroncodonnumber']
    assert_equal 3, genotype.attribute_map['sequencevarianttype']
    assert_equal 2, genotype.attribute_map['moleculartestingtype']
  end

  test 'process_targeted_report_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ8')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No deletions/duplications detected'
    targeted_record.raw_fields['genotype'] = 'Tumour result conf seq +ve'
    targeted_record.raw_fields['report'] = 'Tumour testing for BRCA2 variant c.1234A>G detected in tumour'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 8, genotype.attribute_map['gene'] # BRCA2
    assert_equal 'c.1234A>G', genotype.attribute_map['codingdnasequencechange']
  end

  test 'process_targeted_tumour_result_with_exon' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ9')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No germline variant detected'
    targeted_record.raw_fields['genotype'] = 'Tumour result conf seq +ve'
    targeted_record.raw_fields['report'] = 'Tumour testing for BRCA1. Deletion of exon 5 detected in tumour.'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 7, genotype.attribute_map['gene'] # BRCA1
    assert_equal '5', genotype.attribute_map['exonintroncodonnumber']
    assert_equal 3, genotype.attribute_map['sequencevarianttype']
    assert_equal 1, genotype.attribute_map['moleculartestingtype']
  end

  test 'process_targeted_positive_variant_absent' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ10')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'PALB2 variant absent'
    targeted_record.raw_fields['genotype'] = 'BRCA - Pred B1 C4/C5 seq pos'
    targeted_record.raw_fields['report'] = 'Analysis indicates that the familial pathogenic PALB2 variant c.3116del is absent in this patient.'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 1, genotype.attribute_map['teststatus']
    assert_equal 3186, genotype.attribute_map['gene']
  end

  test 'process_targeted_non_positive_variant_absent_with_brca1' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ11')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'familial variant absent'
    targeted_record.raw_fields['genotype'] = 'BRCA - Pred B1 C4/C5 MLPA neg'
    targeted_record.raw_fields['report'] = 'MLPA analysis indicates that the familial pathogenic BRCA1 duplication of exon 13 is absent in this patient'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 1, genotype.attribute_map['teststatus']
    assert_equal 7, genotype.attribute_map['gene']
  end

  test 'process_targeted_non_positive_variant_absent_with_brca2' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient_targ12')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No variant detected'
    targeted_record.raw_fields['genotype'] = 'Result B2'
    targeted_record.raw_fields['report'] = 'Testing completed'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 1, genotype.attribute_map['teststatus']
    assert_equal 8, genotype.attribute_map['gene'] # BRCA2
  end

  private

  def clinical_json
    { sex: '2',
      consultantcode: 'Consultant Code',
      providercode: 'Provider Code',
      receiveddate: '2019-10-25T00:00:00.000+01:00',
      authoriseddate: '2019-11-25T00:00:00.000+00:00',
      servicereportidentifier: 'Service Report Identifier',
      sortdate: '2019-10-25T00:00:00.000+01:00',
      genetictestscope: 'R208.2',
      specimentype: '12',
      report: 'RESULT\n\nNo pathogenic copy number variants were detected in the PALB2 gene.',
      requesteddate: '2019-10-25T00:00:00.000+01:00',
      age: 999 }.to_json
  end

  def rawtext_clinical_json
    { sex: 'F',
      referringclinicianname: 'Clinician',
      consultantcode: 'Consultant Code',
      servicereportidentifier: 'Service Report Identifier',
      indicationcategory: 'R207',
      specimentype: 'DNA',
      moleculartestingtype: 'R208.2',
      requesteddate: '2021-12-08 00:00:00',
      genotype: 'R208_normal',
      authoriseddate: '2021-12-14 00:00:00',
      provider_address: 'International Centre for Life',
      name: 'Genetics Service',
      report: 'RESULT\n\nNo pathogenic copy number variants were detected in the PALB2 gene.',
      diagnosis_report: 'Germline heterozygous pathogenic variants in PALB2 inherited in an autosomal ' \
                        'dominant manner are associated with a 2-6 fold increased risk of breast cancer ' \
                        'in women. Men with pathogenic variants in the PALB2 gene also have an increased ' \
                        'risk for breast cancer; this risk is much smaller than the risk for women. Pathogenic ' \
                        'variants in PALB2 are also associated with an increased risk of pancreatic cancer. ' \
                        'Biallelic pathogenic variant events cause a subtype of Fanconi anaemia.\n\nReference ' \
                        'sequence: LRG_308t1 (NM_024675.3)\n\n\n\nMLPA analysis carried out using MRC Holland ' \
                        'kit P260-C1.\n\n\n\nDetected variants are assessed at the time of reporting according ' \
                        'to the ACGS best practice guidelines (http://www.acgs.uk.com/). Variant nomenclature ' \
                        'conforms to HGVS guidelines (http://www.hgvs.org). Sequence variants of no or unlikely ' \
                        'clinical significance are omitted from the reported results.',
      patienttype: 'NHS',
      providercode: 'RTD07',
      receiveddate: '2025-09-29 00:00:00',
      karyotypingmethod: 'MLPA P260',
      codingdnasequencechange: 'No deletions/duplications detected',
      proteinimpact: nil,
      gene: nil,
      zygosity: nil,
      variantpathclass: nil }.to_json
  end
end
