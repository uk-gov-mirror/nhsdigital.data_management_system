require 'test_helper'

class LeedsHandlerColorectalV2Test < ActiveSupport::TestCase
  def setup
    @record = build_raw_record('pseudo_id1' => 'bob')
    @genotype = Import::Colorectal::Core::Genocolorectal.new(@record)
    @importer_stdout, @importer_stderr = capture_io do
      @handler = Import::Colorectal::Providers::Leeds::LeedsHandlerColorectalV2.new(EBatch.new)
    end
  end

  test 'process_failed_test_record' do
    failed_record = build_raw_record('pseudo_id1' => 'patient1')
    failed_record.raw_fields['genotype'] = 'Fail/Results not required'
    failed_record.raw_fields['codingdnasequencechange'] = 'No result'
    failed_record.raw_fields['moleculartestingtype'] = 'R210.2'
    failed_record.raw_fields['report'] = 'Unfortunately, no results were obtained from this tissue sample.'

    res = @handler.process_fields(failed_record)
    assert_equal 4, res.size
    res.each do |genotype|
      assert_equal 9, genotype.attribute_map['teststatus']
    end
  end

  test 'process_normal_result_record' do
    res = @handler.process_fields(@record)
    assert_equal 1, res.size
    assert_equal 1, res[0].attribute_map['teststatus'] # normal
    assert_equal 3394, res[0].attribute_map['gene'] # PMS2
  end

  test 'process_result_variant_rec' do
    result_record = build_raw_record('pseudo_id1' => 'patient6')
    result_record.raw_fields['codingdnasequencechange'] = 'PMS2 exons 1-7 deletion heterozygote'
    result_record.raw_fields['report'] = 'MLPA analysis indicates that this patient is heterozygous for a deletion of PMS2 exons 1-7.'

    res = @handler.process_fields(result_record)
    assert_equal 1, res.size

    res.each do |genotype|
      assert_equal 2, genotype.attribute_map['teststatus']
      assert_equal 3394, genotype.attribute_map['gene']
      assert_equal '1-7', genotype.attribute_map['exonintroncodonnumber']
      assert_equal 1, genotype.attribute_map['variantgenotype']
      assert_equal 3, genotype.attribute_map['sequencevarianttype']
    end
  end

  test 'process_protein_impact_variant_rec' do
    gene_record = build_raw_record('pseudo_id1' => 'patient5')
    gene_record.raw_fields['gene'] = nil
    gene_record.raw_fields['codingdnasequencechange'] = 'NTHL1 c.268C>T'
    gene_record.raw_fields['proteinimpact'] = 'APC c.2120T>C het [C3]'
    gene_record.raw_fields['zygosity'] = nil
    gene_record.raw_fields['variantpathclass'] = nil
    gene_record.raw_fields['report'] = 'This patient has been screened for variants in the following cancer predisposing genes by sequence analysis:\n\nAPC, BMPR1A, EPCAM*, GREM1*, MLH1, MSH2, MSH6, MUTYH, NTHL1, PMS2, POLD1, POLE, PTEN, RNF43, SMAD4, STK11'

    res = @handler.process_fields(gene_record)
    assert_equal 2, res.size

    # APC variant should get c.2120T>C from proteinimpact field
    protein_variant_genotype = res.find { |g| g.attribute_map['gene'] == 358 } # APC
    assert_equal 'c.2120T>C', protein_variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 2, protein_variant_genotype.attribute_map['teststatus']

    # NTHL1 variant should get c.268C>T from codingdnasequencechange field
    result_variant_genotype = res.find { |g| g.attribute_map['gene'] == 3108 } # NTHL1
    assert_equal 'c.268C>T', result_variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 2, result_variant_genotype.attribute_map['teststatus']
  end

  test 'gene_variant_rec' do
    gene_record = build_raw_record('pseudo_id1' => 'patient5')
    gene_record.raw_fields['gene'] = 'MLH1'
    gene_record.raw_fields['codingdnasequencechange'] = 'exon 16-19 deletion'
    gene_record.raw_fields['proteinimpact'] = nil
    gene_record.raw_fields['zygosity'] = 'Heterozygous'
    gene_record.raw_fields['variantpathclass'] = 'Pathogenic'
    gene_record.raw_fields['report'] = 'A germline pathogenic MLH1 copy number variant was detected in this patient sample'
    gene_record.raw_fields['diagnosis_report'] = '1. Genes screened in the panel: MLH1, MSH2, MSH6, PMS2 (all coding exons and exon-intron boundaries).'
    res = @handler.process_fields(gene_record)
    assert_equal 4, res.size

    gene_variant_genotype = res.find { |g| g.attribute_map['gene'] == 2744 } # MLH1
    assert_equal '16-19', gene_variant_genotype.attribute_map['exonintroncodonnumber']
    assert_equal 2, gene_variant_genotype.attribute_map['teststatus']
    assert_equal 5, gene_variant_genotype.attribute_map['variantpathclass']

    res.each do |genotype|
      next if genotype.attribute_map['gene'] == 2744

      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'normal_result_rec' do
    normal_record = build_raw_record('pseudo_id1' => 'patient7')
    normal_record.raw_fields['codingdnasequencechange'] = 'No deletions/duplications detected'
    normal_record.raw_fields['report'] = 'MLPA analysis indicates that the potential PMS2 copy number variant identified by NGS is absent in this patient.'
    normal_record.raw_fields['genotype'] = 'PMS2 - MLPA conf negative'
    normal_record.raw_fields['moleculartestingtype'] = nil

    res = @handler.process_fields(normal_record)
    assert_equal 1, res.size

    res.each do |genotype|
      assert_equal 1, genotype.attribute_map['teststatus'] # normal
    end
  end

  test 'normal_report_result_rec' do
    normal_record = build_raw_record('pseudo_id1' => 'patient7')
    normal_record.raw_fields['report'] = 'This patient has been screened for MLH1, MSH2, MSH6 and PMS2 variants by sequence analysis. No pathogenic variant was identified.'
    normal_record.raw_fields['genotype'] = 'Lynch Diag; normal'
    normal_record.raw_fields['proteinimpact'] = nil
    normal_record.raw_fields['gene'] = nil
    normal_record.raw_fields['codingdnasequencechange'] = 'No result'

    res = @handler.process_fields(normal_record)
    assert_equal 4, res.size

    res.each do |genotype|
      assert_equal 1, genotype.attribute_map['teststatus'] # normal
    end
  end

  test 'first_of_report_variant_rec' do
    first_record = build_raw_record('pseudo_id1' => 'patient8')
    first_record.raw_fields['codingdnasequencechange'] = 'No result'
    first_record.raw_fields['proteinimpact'] = nil
    first_record.raw_fields['gene'] = nil
    first_record.raw_fields['report'] = 'This patient has been screened for variants in the following cancer predisposing genes by sequence analysis:' \
                                        'APC, BMPR1A, EPCAM*, GREM1*, MLH1, MSH2, MSH6, MUTYH, NTHL1, PMS2, POLD1, POLE, PTEN, RNF43, SMAD4, STK11.This patient is heterozygous for the ' \
                                        'pathogenic NTHL1 variants c.268C>T p.(Gln90Ter)'
    first_record.raw_fields['moleculartestingtype'] = 'R211'

    res = @handler.process_fields(first_record)
    assert_equal 16, res.size
    variant_genotype = res.find { |g| g.attribute_map['gene'] == 3108 } # NTHL1
    assert_not_nil variant_genotype
    assert_equal 'c.268C>T', variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 'p.Gln90Ter', variant_genotype.attribute_map['proteinimpact']
    assert_equal 2, variant_genotype.attribute_map['teststatus']

    res.each do |genotype|
      next if genotype.attribute_map['gene'] == 3108

      assert_equal 1, genotype.attribute_map['teststatus']
      assert_equal 'Full screen Colorectal Lynch or MMR', genotype.attribute_map['genetictestscope']
    end
  end

  # targeted tests
  test 'zygosity_variant_targ_rec' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient10')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['zygosity'] = 'Heterozygous'
    targeted_record.raw_fields['gene'] = 'MSH2'
    targeted_record.raw_fields['variantpathclass'] = 'Pathogenic'
    targeted_record.raw_fields['codingdnasequencechange'] = 'NM_000251.2:exon 11-16 deletion'
    targeted_record.raw_fields['genotype'] = 'R242_pos_MLPA'
    targeted_record.raw_fields['report'] = 'This individual is heterozygous for the germline familial pathogenic MSH2 copy number variant'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 2804, genotype.attribute_map['gene'] # APC
    assert_equal '11-16', genotype.attribute_map['exonintroncodonnumber']
    assert_equal 'NM_000251.2', genotype.attribute_map['referencetranscriptid']
    assert_equal 'Targeted Colorectal Lynch or MMR', genotype.attribute_map['genetictestscope']
    assert_equal 5, genotype.attribute_map['variantpathclass']
    assert_equal 4, genotype.attribute_map['geneticinheritance']
  end

  test 'process_targeted_mosaic_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient11')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['zygosity'] = 'Mosaic'
    targeted_record.raw_fields['gene'] = 'PMS2'
    targeted_record.raw_fields['codingdnasequencechange'] = 'NM_000535.5:Whole gene deletion'
    targeted_record.raw_fields['genotype'] = 'R443_Confirmation_NGS_MLPA_PMS2'
    targeted_record.raw_fields['report'] = 'This patient shows mosaic pattern for the familial MLH1 variant'
    targeted_record.raw_fields['variantpathclass'] = 'Pathogenic'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 3394, genotype.attribute_map['gene'] # PMS2
    assert_equal 'NM_000535.5', genotype.attribute_map['referencetranscriptid']
    assert_equal 6, genotype.attribute_map['geneticinheritance']
    assert_equal 5, genotype.attribute_map['variantpathclass']
  end

  test 'process_targeted_variant_absent' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient12')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'NM_000251.2:Exon 1-7 deletion'
    targeted_record.raw_fields['genotype'] = 'R242_neg_MLPA'
    targeted_record.raw_fields['report'] = 'Dosage analysis has shown no evidence of the familial pathogenic MSH2 variant.'
    targeted_record.raw_fields['proteinimpact'] = nil
    targeted_record.raw_fields['zygosity'] = 'Variant NOT detected'
    targeted_record.raw_fields['gene'] = 'MSH2'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 1, genotype.attribute_map['teststatus']
    assert_equal 2804, genotype.attribute_map['gene'] # MSH2
  end

  test 'process_targeted_no_result' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient13')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No result'
    targeted_record.raw_fields['genotype'] = 'Fail/Results not required'
    targeted_record.raw_fields['report'] = 'No results were obtained from this sample despite repeated attempts'
    targeted_record.raw_fields['proteinimpact'] = nil
    targeted_record.raw_fields['zygosity'] = nil
    targeted_record.raw_fields['gene'] = nil
    targeted_record.raw_fields['diagnosis_report'] = 'Germline heterozygous pathogenic variants in PTEN are associated with PTEN hamartoma tumour syndrome'

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 9, genotype.attribute_map['teststatus']
    assert_equal 62, genotype.attribute_map['gene']
  end

  test 'process_targeted_no_biallelic' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient14')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'No biallelic presence of familial variant'
    targeted_record.raw_fields['genotype'] = 'PMS2 - Biallelic (CMMRD) pred negative'
    targeted_record.raw_fields['report'] = 'Sequence analysis indicates no biallelic presence of the familial pathogenic PMS2 variant c.2404C>T in this patient.'
    targeted_record.raw_fields['proteinimpact'] = nil
    targeted_record.raw_fields['zygosity'] = nil
    targeted_record.raw_fields['gene'] = nil

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 4, genotype.attribute_map['teststatus']
    assert_equal 3394, genotype.attribute_map['gene'] # PMS2
  end

  test 'process_targeted_cdna_het_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient15')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'MSH2 Exon 11-12 duplication heterozygote'
    targeted_record.raw_fields['genotype'] = 'Lynch Pred MLPA +ve'
    targeted_record.raw_fields['report'] = 'MLPA analysis indicates that this patient is heterozygous for the familial likely pathogenic MSH2 duplication of exons 11-12'
    targeted_record.raw_fields['proteinimpact'] = nil
    targeted_record.raw_fields['zygosity'] = nil
    targeted_record.raw_fields['gene'] = nil

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 2, genotype.attribute_map['teststatus']
    assert_equal 2804, genotype.attribute_map['gene'] # MSH2
    assert_equal '11-12', genotype.attribute_map['exonintroncodonnumber']
    assert_equal 4, genotype.attribute_map['sequencevarianttype']
  end

  test 'process_result_variant_absent_variant' do
    targeted_record = build_raw_record('pseudo_id1' => 'patient15')
    targeted_record.raw_fields['moleculartestingtype'] = 'Familial'
    targeted_record.raw_fields['codingdnasequencechange'] = 'familial variant absent'
    targeted_record.raw_fields['genotype'] = 'Lynch Pred MLPA -ve'
    targeted_record.raw_fields['report'] = 'MLPA analysis indicates that the familial pathogenic MLH1 exon 16-19 deletion is absent in this patient.'
    targeted_record.raw_fields['proteinimpact'] = nil
    targeted_record.raw_fields['zygosity'] = nil
    targeted_record.raw_fields['gene'] = nil

    res = @handler.process_fields(targeted_record)
    assert_equal 1, res.size

    genotype = res[0]
    assert_equal 1, genotype.attribute_map['teststatus']
    assert_equal 2744, genotype.attribute_map['gene'] # MLH1
  end

  # Tests for should_process? method
  test 'should_process_other_cancer_file_familial' do
    @handler.instance_variable_set(:@batch, stub(original_filename: 'Other_Cancer_file.txt'))

    record = build_raw_record('pseudo_id1' => 'patient16')
    record.raw_fields['moleculartestingtype'] = 'Familial'
    record.raw_fields['report'] = 'Testing for MLH1 variants'

    assert @handler.send(:should_process?, record)
  end

  test 'should_not_process_other_cancer_file_non_familial' do
    @handler.instance_variable_set(:@batch, stub(original_filename: 'Other_Cancer_file.txt'))

    record = build_raw_record('pseudo_id1' => 'patient17')
    record.raw_fields['moleculartestingtype'] = 'Predictive'
    record.raw_fields['report'] = 'Testing for MLH1 variants'

    refute @handler.send(:should_process?, record)
  end

  test 'should_not_process_ataxia_record' do
    @handler.instance_variable_set(:@batch, stub(original_filename: 'Other_Cancer_file.txt'))

    record = build_raw_record('pseudo_id1' => 'patient18')
    record.raw_fields['moleculartestingtype'] = 'Familial'
    record.raw_fields['diagnosis_report'] = 'Testing for ataxia related genes'
    record.raw_fields['report'] = 'MLH1 testing'

    refute @handler.send(:should_process?, record)
  end

  test 'should_not_process_brca_record' do
    @handler.instance_variable_set(:@batch, stub(original_filename: 'Other_Cancer_file.txt'))

    record = build_raw_record('pseudo_id1' => 'patient19')
    record.raw_fields['moleculartestingtype'] = 'Familial'
    record.raw_fields['codingdnasequencechange'] = 'BRCA1 c.181T>G'
    record.raw_fields['report'] = 'MLH1 testing'

    refute @handler.send(:should_process?, record)
  end

  private

  def clinical_json
    { sex: '2',
      consultantcode: 'Consultant Code',
      providercode: 'Provider Code',
      receiveddate: '2010-08-05T00:00:00.000+01:00',
      authoriseddate: '2010-09-17T00:00:00.000+01:00',
      servicereportidentifier: 'Service Report Identifier',
      sortdate: '2010-08-05T00:00:00.000+01:00',
      genetictestscope: 'R210.2',
      specimentype: '5',
      report: 'MLPA analysis indicates that the potential PMS2 copy number variant identified by NGS is absent in this patient.',
      requesteddate: '2010-08-05T00:00:00.000+01:00',
      age: 37 }.to_json
  end

  def rawtext_clinical_json
    { sex: 'M',
      providercode: 'Provider Code',
      referringclinicianname: 'Clinician Name',
      consultantcode: 'Consultant Code',
      servicereportidentifier: 'Service Report Identifier',
      patienttype: 'NHS',
      moleculartestingtype: 'R210.5',
      indicationcategory: 'R210',
      genotype: 'PMS2 - MLPA conf negative',
      report: 'MLPA analysis indicates that the potential PMS2 copy number variant identified by NGS is absent in this patient',
      diagnosis_report: 'Heterozygous mutations in PMS2 are linked to Lynch Syndrome with dominant inheritance. ' \
                        'Homozygous/compound heterozygous mutations in PMS2 are linked to mismatch repair cancer syndrome.',
      receiveddate: '2010-08-05 00:00:00',
      karyotypingmethod: 'MLPA P008',
      codingdnasequencechange: 'No deletions/duplications detected',
      proteinimpact: nil,
      gene: nil,
      zygosity: nil,
      variantpathclass: nil,
      requesteddate: '2010-08-05 00:00:00',
      authoriseddate: '2010-09-17 00:00:00',
      specimentype: 'Blood' }.to_json
  end
end
