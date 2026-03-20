require 'test_helper'

class SheffieldHandlerTest < ActiveSupport::TestCase
  def setup
    @record   = build_raw_record('pseudo_id1' => 'bob')
    @genotype = Import::Brca::Core::GenotypeBrca.new(@record)
    @importer_stdout, @importer_stderr = capture_io do
      @handler = Import::Brca::Providers::Sheffield::SheffieldHandler.new(EBatch.new)
    end

    @logger = Import::Log.get_logger
  end

  test 'add_test_scope_from_geno_karyo' do
    @logger.expects(:debug).with('ADDED TARGETED TEST for: BRCA cDNA analysis')
    @handler.add_test_scope_from_geno_karyo(@genotype, @record)
    assert_equal 'Targeted BRCA mutation test', @genotype.attribute_map['genetictestscope']

    fullscreen_record = build_raw_record('pseudo_id1' => 'bob')
    fullscreen_record.raw_fields['karyotypingmethod'] = 'BRCA1 and 2 gene sequencing'
    @logger.expects(:debug).with('ADDED FULL_SCREEN TEST for: BRCA1 and 2 gene sequencing')
    @handler.add_test_scope_from_geno_karyo(@genotype, fullscreen_record)
    assert_equal 'Full screen BRCA1 and BRCA2', @genotype.attribute_map['genetictestscope']

    nogenetictest_record = build_raw_record('pseudo_id1' => 'bob')
    nogenetictest_record.raw_fields['genetictestscope'] = 'R216 :: Li Fraumeni Syndrome - SDGS'
    nogenetictest_record.raw_fields['karyotypingmethod'] = 'R216.1 :: TP53 NGS in Leeds Analysis only'
    @handler.add_test_scope_from_geno_karyo(@genotype, nogenetictest_record)
    assert_equal 'Unable to assign BRCA genetictestscope', @genotype.attribute_map['genetictestscope']
  end

  test 'add_test_type from moleculartestingtype mapping' do
    @handler.add_test_type(@genotype, @record)
    assert_equal 2, @genotype.attribute_map['moleculartestingtype']
    mtype_record = build_raw_record('pseudo_id1' => 'bob')
    mtype_record.raw_fields['moleculartestingtype'] = 'Testing for unaffected family member'
    @handler.add_test_type(@genotype, mtype_record)
    assert_equal 2, @genotype.attribute_map['moleculartestingtype'] # :predictive
  end

  test 'add_test_type from karyo when moleculartestingtype cannot be determined' do
    karyo_mtype_record = build_raw_record('pseudo_id1' => 'bob')
    karyo_mtype_record.raw_fields['moleculartestingtype'] = ''
    karyo_mtype_record.raw_fields['karyotypingmethod'] = 'R240.1 :: Some test'
    @handler.add_test_type(@genotype, karyo_mtype_record)
    assert_equal 1, @genotype.attribute_map['moleculartestingtype'] # :diagnostic
    karyo_mtype_record.raw_fields['karyotypingmethod'] = 'R242.1 :: Predictive testing'
    @handler.add_test_type(@genotype, karyo_mtype_record)
    assert_equal 2, @genotype.attribute_map['moleculartestingtype'] # :predictive
    karyo_mtype_record.raw_fields['karyotypingmethod'] = 'R448.1 :: Prenatal testing'
    @handler.add_test_type(@genotype, karyo_mtype_record)
    assert_equal 4, @genotype.attribute_map['moleculartestingtype'] # :prenatal
  end

  test 'add_test_type moleculartestingtype takes priority over karyo' do
    priority_record = build_raw_record('pseudo_id1' => 'bob')
    priority_record.raw_fields['moleculartestingtype'] = 'Diagnostic testing'
    priority_record.raw_fields['karyotypingmethod'] = 'R242.1 :: Predictive testing'
    @handler.add_test_type(@genotype, priority_record)
    # Should be diagnostic from moleculartestingtype, not predictive from karyo
    assert_equal 1, @genotype.attribute_map['moleculartestingtype']
  end

  test 'process_variants_from_record' do
    @handler.add_test_scope_from_geno_karyo(@genotype, @record)
    genotypes = @handler.process_variants_from_record(@genotype, @record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 'c.[520C>T]', genotypes[0].attribute_map['codingdnasequencechange']
    assert_nil genotypes[0].attribute_map['proteinimpact']
    assert_equal 8, genotypes[0].attribute_map['gene']
  end

  test 'mlpa_fail_full_screen' do
    mlpa_fail_fs_record = build_raw_record('pseudo_id1' => 'bob')
    mlpa_fail_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    mlpa_fail_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 & BRCA2 only'
    mlpa_fail_fs_record.raw_fields['genotype'] = 'No pathogenic mutation detected - BRCA2 MLPA failed'
    @handler.add_test_scope_from_geno_karyo(@genotype, mlpa_fail_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, mlpa_fail_fs_record)
    assert_equal 2, genotypes.size
    # MLPA failed gene
    assert_equal 8, genotypes[0].attribute_map['gene']
    assert_equal 9, genotypes[0].attribute_map['teststatus']
    # MLPA method
    assert_equal 15, genotypes[0].attribute_map['karyotypingmethod']
    # Rest negative genes
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_equal 7, genotypes[1].attribute_map['gene']
  end

  test 'normal_full_screen' do
    normal_fs_record = build_raw_record('pseudo_id1' => 'bob')
    normal_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    normal_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 and BRCA2'
    normal_fs_record.raw_fields['genotype'] = 'No pathogenic mutation detected'
    @handler.add_test_scope_from_geno_karyo(@genotype, normal_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, normal_fs_record)
    assert_equal 2, genotypes.size
    assert_equal 1, genotypes[0].attribute_map['teststatus']
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_nil  genotypes[0].attribute_map['proteinimpact']
    assert_nil  genotypes[1].attribute_map['codingdnasequencechange']
  end

  test 'normal_full_screen_new_variable' do
    normal_fs_record = build_raw_record('pseudo_id1' => 'bob')
    normal_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    normal_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 and BRCA2'
    normal_fs_record.raw_fields['genotype'] = 'A genetic cause for this individuals clinical presentation has not been identified'
    @handler.add_test_scope_from_geno_karyo(@genotype, normal_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, normal_fs_record)
    assert_equal 2, genotypes.size
    assert_equal 1, genotypes[0].attribute_map['teststatus']
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_nil  genotypes[0].attribute_map['proteinimpact']
    assert_nil  genotypes[1].attribute_map['codingdnasequencechange']
  end

  test 'failed_full_screen' do
    fail_fs_record = build_raw_record('pseudo_id1' => 'bob')
    fail_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    fail_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 and BRCA2'
    fail_fs_record.raw_fields['genotype'] = 'FAIL'
    @handler.add_test_scope_from_geno_karyo(@genotype, fail_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, fail_fs_record)
    assert_equal 2, genotypes.size
    assert_equal 9, genotypes[0].attribute_map['teststatus']
    assert_equal 9, genotypes[1].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_equal 'Full screen BRCA1 and BRCA2', genotypes[0].attribute_map['genetictestscope']
  end

  test 'multiple_variant_fs_record' do
    multiple_variant_fs_record = build_raw_record('pseudo_id1' => 'bob')
    multiple_variant_fs_record.raw_fields['genetictestscope'] = 'R208 :: BRCA1 and BRCA2 testing at high familial risk'
    multiple_variant_fs_record.raw_fields['karyotypingmethod'] = 'R208.1 :: Unknown mutation(s) by Single gene sequencing'
    multiple_variant_fs_record.raw_fields['genotype'] = 'BRCA2: c.9175A>G:p.Lys3059Glu PALB2: c.1250C>A:p.Ser417Tyr - see comments'
    @handler.add_test_scope_from_geno_karyo(@genotype, multiple_variant_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, multiple_variant_fs_record)
    assert_equal %w[BRCA1 BRCA2 PALB2], @handler.instance_variable_get('@genes_set')
    assert_equal 3, genotypes.size

    # positive genes
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 'p.Lys3059Glu', genotypes[0].attribute_map['proteinimpact']
    assert_equal 'c.9175A>G', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 8, genotypes[0].attribute_map['gene']

    assert_equal 2, genotypes[1].attribute_map['teststatus']
    assert_equal 'p.Ser417Tyr', genotypes[1].attribute_map['proteinimpact']
    assert_equal 'c.1250C>A', genotypes[1].attribute_map['codingdnasequencechange']
    assert_equal 3186, genotypes[1].attribute_map['gene']

    # negative gene
    assert_equal 1, genotypes[2].attribute_map['teststatus']
    assert_nil  genotypes[2].attribute_map['proteinimpact']
    assert_nil  genotypes[2].attribute_map['codingdnasequencechange']
    assert_equal 7, genotypes[2].attribute_map['gene']
  end

  test 'single_variant_fs_record' do
    single_variant_fs_record = build_raw_record('pseudo_id1' => 'bob')
    single_variant_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    single_variant_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 & BRCA2 only'
    single_variant_fs_record.raw_fields['genotype'] = 'BRCA1: c.[4986+4_4986+13del];[=]'
    @handler.add_test_scope_from_geno_karyo(@genotype, single_variant_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, single_variant_fs_record)
    assert_equal %w[BRCA1 BRCA2], @handler.instance_variable_get('@genes_set')
    assert_equal 2, genotypes.size

    # positive genes
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_nil genotypes[0].attribute_map['proteinimpact']
    assert_equal 'c.[4986+4_4986+13del]', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 7, genotypes[0].attribute_map['gene']

    # negative gene
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_nil  genotypes[1].attribute_map['proteinimpact']
    assert_nil  genotypes[1].attribute_map['codingdnasequencechange']
    assert_equal 8, genotypes[1].attribute_map['gene']
  end

  test 'only_protein_fs_record' do
    protein_fs_record = build_raw_record('pseudo_id1' => 'bob')
    protein_fs_record.raw_fields['genetictestscope'] = 'BRCA1 and 2 gene analysis'
    protein_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 and 2 gene sequencing'
    protein_fs_record.raw_fields['genotype'] = 'p.[(Leu1768fs)];[=]'
    @handler.add_test_scope_from_geno_karyo(@genotype, protein_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, protein_fs_record)
    assert_equal %w[BRCA1 BRCA2], @handler.instance_variable_get('@genes_set')
    assert_equal 2, genotypes.size
    assert_equal 4, genotypes[0].attribute_map['teststatus']
    assert_equal 4, genotypes[1].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_equal 'Full screen BRCA1 and BRCA2', genotypes[0].attribute_map['genetictestscope']
  end

  test 'multi_genes_targeted' do
    multi_genes_tar_record = build_raw_record('pseudo_id1' => 'bob')
    multi_genes_tar_record.raw_fields['genetictestscope'] = 'R208 :: BRCA1 and BRCA2 testing at high familial risk'
    multi_genes_tar_record.raw_fields['karyotypingmethod'] = 'R242.1 :: Predictive testing'
    multi_genes_tar_record.raw_fields['genotype'] = 'BRCA1: pathogenic heterozygous deletion involving exons 1 and 2 BRCA2: c.[7069_7070del];[7069_7070=], p.[(Leu2357fs)];[(Leu2357=)]'
    @handler.add_test_scope_from_geno_karyo(@genotype, multi_genes_tar_record)
    genotypes = @handler.process_variants_from_record(@genotype, multi_genes_tar_record)
    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
    assert_equal 2, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal '1and2', genotypes[0].attribute_map['exonintroncodonnumber']
    assert_equal 3, genotypes[0].attribute_map['sequencevarianttype']
    assert_equal 1, genotypes[0].attribute_map['variantlocation']

    assert_equal 2, genotypes[1].attribute_map['teststatus']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_equal 'c.[7069_7070del]', genotypes[1].attribute_map['codingdnasequencechange']
    assert_equal 'p.Leu2357fs', genotypes[1].attribute_map['proteinimpact']
  end

  test 'normal_targeted' do
    normal_tar_record = build_raw_record('pseudo_id1' => 'bob')
    normal_tar_record.raw_fields['genetictestscope'] = 'R206 :: Inherited breast cancer and ovarian cancer at high familial risk levels'
    normal_tar_record.raw_fields['karyotypingmethod'] = 'R242.1 :: Predictive testing'
    normal_tar_record.raw_fields['genotype'] = 'Familal BRCA1 pathogenic mutation NOT detected - See Comment'
    @handler.add_test_scope_from_geno_karyo(@genotype, normal_tar_record)
    genotypes = @handler.process_variants_from_record(@genotype, normal_tar_record)

    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
    assert_equal 1, genotypes.size
    assert_equal 1, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_nil genotypes[0].attribute_map['exonintroncodonnumber']
    assert_nil  genotypes[0].attribute_map['proteinimpact']
    assert_nil  genotypes[0].attribute_map['codingdnasequencechange']
  end

  test 'failed_targ' do
    fail_tar_record = build_raw_record('pseudo_id1' => 'bob')
    fail_tar_record.raw_fields['genetictestscope'] = 'BRCA1 and 2 gene analysis'
    fail_tar_record.raw_fields['karyotypingmethod'] = 'BRCA2 gene sequencing'
    fail_tar_record.raw_fields['genotype'] = 'BRCA2: sequencing failed'
    @handler.add_test_scope_from_geno_karyo(@genotype, fail_tar_record)
    genotypes = @handler.process_variants_from_record(@genotype, fail_tar_record)
    assert_equal 1, genotypes.size
    assert_equal 9, genotypes[0].attribute_map['teststatus']
    assert_equal 8, genotypes[0].attribute_map['gene']
    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
  end

  test 'protein_targeted' do
    protein_tar_record = build_raw_record('pseudo_id1' => 'bob')
    protein_tar_record.raw_fields['genetictestscope'] = 'BRCA1 and 2 gene analysis'
    protein_tar_record.raw_fields['karyotypingmethod'] = 'BRCA1 gene sequencing'
    protein_tar_record.raw_fields['genotype'] = 'p.[(Leu392fs)];[=]'
    @handler.add_test_scope_from_geno_karyo(@genotype, protein_tar_record)
    genotypes = @handler.process_variants_from_record(@genotype, protein_tar_record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_nil genotypes[0].attribute_map['exonintroncodonnumber']
    assert_equal 'p.Leu392fs', genotypes[0].attribute_map['proteinimpact']
    assert_equal 'c.', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
  end

  test 'detected_but_no_mutation_targeted' do
    detected_tar_record = build_raw_record('pseudo_id1' => 'bob')
    detected_tar_record.raw_fields['genetictestscope'] = 'BRCA1 and 2 gene analysis'
    detected_tar_record.raw_fields['karyotypingmethod'] = 'BRCA1 gene sequencing'
    detected_tar_record.raw_fields['genotype'] = 'Familial mutation detected'
    @handler.add_test_scope_from_geno_karyo(@genotype, detected_tar_record)
    genotypes = @handler.process_variants_from_record(@genotype, detected_tar_record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_nil genotypes[0].attribute_map['exonintroncodonnumber']
    assert_equal 'p.', genotypes[0].attribute_map['proteinimpact']
    assert_equal 'c.', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
  end

  test 'malformed_mutation_fs' do
    malformed_mutation_fs_record = build_raw_record('pseudo_id1' => 'bob')
    malformed_mutation_fs_record.raw_fields['genetictestscope'] = 'Breast & Ovarian cancer panel'
    malformed_mutation_fs_record.raw_fields['karyotypingmethod'] = 'BRCA1 & BRCA2 only'
    malformed_mutation_fs_record.raw_fields['genotype'] = 'BRCA2 c[8575del];[=]  p.[(Gln2859fs)];[(=)]'
    @handler.add_test_scope_from_geno_karyo(@genotype, malformed_mutation_fs_record)
    genotypes = @handler.process_variants_from_record(@genotype, malformed_mutation_fs_record)
    assert_equal 2, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_equal 8, genotypes[0].attribute_map['gene']
    assert_equal 7, genotypes[1].attribute_map['gene']
    assert_nil genotypes[0].attribute_map['exonintroncodonnumber']
    assert_equal 'p.Gln2859fs', genotypes[0].attribute_map['proteinimpact']
    assert_equal 'c.[8575del]', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 'Full screen BRCA1 and BRCA2', genotypes[0].attribute_map['genetictestscope']
    assert_equal 'Full screen BRCA1 and BRCA2', genotypes[1].attribute_map['genetictestscope']
  end

  test 'mutation_but_no_gene_target' do
    mutation_no_gene_targ_record = build_raw_record('pseudo_id1' => 'bob')
    mutation_no_gene_targ_record.raw_fields['genetictestscope'] = 'R208 :: BRCA1 and BRCA2 testing at high familial risk'
    mutation_no_gene_targ_record.raw_fields['karyotypingmethod'] = 'R242.1 :: Predictive testing'
    mutation_no_gene_targ_record.raw_fields['genotype'] = '[c.3607C>T];[3607=] p.[(Arg1203*)];[(Arg1203=)] Heterozygous result'
    @handler.add_test_scope_from_geno_karyo(@genotype, mutation_no_gene_targ_record)
    genotypes = @handler.process_variants_from_record(@genotype, mutation_no_gene_targ_record)
    assert_equal 1, genotypes.size
    assert_equal 4, genotypes[0].attribute_map['teststatus']
    assert_nil  genotypes[0].attribute_map['proteinimpact']
    assert_nil  genotypes[0].attribute_map['codingdnasequencechange']
    assert_nil genotypes[0].attribute_map['gene']
    assert_equal 'Targeted BRCA mutation test', genotypes[0].attribute_map['genetictestscope']
  end

  test 'normal_full_screen_not_identified_case' do
    normal_fs_not_identfied_record = build_raw_record('pseudo_id1' => 'bob')
    normal_fs_not_identfied_record.raw_fields['genetictestscope'] = 'R208 :: BRCA1 and BRCA2 testing at high familial risk'
    normal_fs_not_identfied_record.raw_fields['karyotypingmethod'] = 'R208.1 :: NGS in Leeds'
    normal_fs_not_identfied_record.raw_fields['genotype'] = 'A hereditary (germline) genetic cause for this individual’s cancer has not been identified;'
    @handler.add_test_scope_from_geno_karyo(@genotype, normal_fs_not_identfied_record)
    genotypes = @handler.process_variants_from_record(@genotype, normal_fs_not_identfied_record)
    assert_equal 3, genotypes.size
    assert_equal 1, genotypes[0].attribute_map['teststatus']
    assert_equal 1, genotypes[1].attribute_map['teststatus']
    assert_equal 1, genotypes[2].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 8, genotypes[1].attribute_map['gene']
    assert_equal 3186, genotypes[2].attribute_map['gene']
    assert_nil  genotypes[0].attribute_map['proteinimpact']
    assert_nil  genotypes[1].attribute_map['codingdnasequencechange']
  end

  test 'process_scope_r207 with R207.1 full screen' do
    r207_1_record = build_raw_record('pseudo_id1' => 'bob')
    r207_1_record.raw_fields['genetictestscope'] = 'R207 :: Inherited ovarian cancer (without breast cancer)'
    r207_1_record.raw_fields['karyotypingmethod'] = 'R207.1 :: NGS in Leeds'
    r207_1_record.raw_fields['genotype'] = 'BRCA1-c.5266dup-p.(Gln1756fs)-Heterozygous-UV5;MSH6-c.3649A>G-p.(Arg1217Gly)-Heterozygous-UV3'
    @handler.add_test_scope_from_geno_karyo(@genotype, r207_1_record)
    assert_equal 'Full screen BRCA1 and BRCA2', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r207_1_record)
    assert_equal 11, genotypes.size
    variant_genotype_brca = genotypes.find { |g| g.attribute_map['gene'] == 7 } # BRCA1
    assert_equal 2, variant_genotype_brca.attribute_map['teststatus']
    assert_equal 'c.5266dup', variant_genotype_brca.attribute_map['codingdnasequencechange']
    assert_equal 'p.Gln1756fs', variant_genotype_brca.attribute_map['proteinimpact']

    variant_genotype_msh6 = genotypes.find { |g| g.attribute_map['gene'] == 2808 } # MSH6
    assert_equal 2, variant_genotype_msh6.attribute_map['teststatus']
    assert_equal 'c.3649A>G', variant_genotype_msh6.attribute_map['codingdnasequencechange']
    assert_equal 'p.Arg1217Gly', variant_genotype_msh6.attribute_map['proteinimpact']
    genotypes.each do |genotype|
      next if [7, 2808].include?(genotype.attribute_map['gene'])

      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'process_scope_r207 with R240 targeted' do
    r207_r240_record = build_raw_record('pseudo_id1' => 'bob')
    r207_r240_record.raw_fields['genetictestscope'] = 'R207'
    r207_r240_record.raw_fields['karyotypingmethod'] = 'R240 :: Diagnostic testing for known pathogenic variant(s) - Hereditary Cancers'
    r207_r240_record.raw_fields['genotype'] = 'Genetic diagnosis of BRCA2-related cancer susceptibility; BRCA2(NM_000059.3);c.4218_4221del;p.(Lys1406Asnfs*3);Heterozygous;UV5'
    @handler.add_test_scope_from_geno_karyo(@genotype, r207_r240_record)
    assert_equal 'Targeted BRCA mutation test', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r207_r240_record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 8, genotypes[0].attribute_map['gene']
    assert_equal 'c.4218_4221del', genotypes[0].attribute_map['codingdnasequencechange']
    assert_equal 'p.Lys1406AsnfsTer3', genotypes[0].attribute_map['proteinimpact']
  end

  test 'process_scope_r208_new with R242 targeted' do
    r208_r242_record = build_raw_record('pseudo_id1' => 'bob')
    r208_r242_record.raw_fields['genetictestscope'] = 'R208'
    r208_r242_record.raw_fields['karyotypingmethod'] = 'R242 :: Predictive testing for known familial pathogenic variant(s) - Hereditary Cancers'
    r208_r242_record.raw_fields['genotype'] = 'At elevated risk of BRCA1 and BRCA2-related cancers; BRCA1(NM_007294.3);deletion including exons 1-2Heterozygous;'
    @handler.add_test_scope_from_geno_karyo(@genotype, r208_r242_record)
    assert_equal 'Targeted BRCA mutation test', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r208_r242_record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
  end

  test 'process_scope_r430 with R430 full screen' do
    r430_record = build_raw_record('pseudo_id1' => 'bob')
    r430_record.raw_fields['genetictestscope'] = 'R430 :: Inherited Prostate Cancer'
    r430_record.raw_fields['karyotypingmethod'] = 'R430.1 :: NGS in Leeds'
    r430_record.raw_fields['genotype'] = 'Genetic diagnosis of CHEK2-related cancer susceptibility; CHEK2(NM_007194.4);c.1100del;p.(Glu1493fs);Heterozygous;UV5'
    @handler.add_test_scope_from_geno_karyo(@genotype, r430_record)
    assert_equal 'Full screen BRCA1 and BRCA2', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r430_record)
    assert_equal 8, genotypes.size
    variant_genotype = genotypes.find { |g| g.attribute_map['gene'] == 865 } # CHEK2
    assert_equal 2, variant_genotype.attribute_map['teststatus']
    assert_equal 'c.1100del', variant_genotype.attribute_map['codingdnasequencechange']
    assert_equal 'p.Glu1493fs', variant_genotype.attribute_map['proteinimpact']

    genotypes.each do |genotype|
      next if genotype.attribute_map['gene'] == 865

      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'process_scope_r207 with R387.1 targeted' do
    r207_r387_1_record = build_raw_record('pseudo_id1' => 'bob')
    r207_r387_1_record.raw_fields['genetictestscope'] = 'R207'
    r207_r387_1_record.raw_fields['karyotypingmethod'] = 'R387.1 :: Reanalysis of existing NGS data'
    r207_r387_1_record.raw_fields['genotype'] = 'No variant detected'
    @handler.add_test_scope_from_geno_karyo(@genotype, r207_r387_1_record)
    assert_equal 'Full screen BRCA1 and BRCA2', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r207_r387_1_record)
    assert_equal 11, genotypes.size
    genotypes.each do |genotype|
      assert_not_nil genotype.attribute_map['gene']
      assert_equal 1, genotype.attribute_map['teststatus']
    end
  end

  test 'process_scope_r208 with R370.1 targeted' do
    r208_r370_1_record = build_raw_record('pseudo_id1' => 'bob')
    r208_r370_1_record.raw_fields['genetictestscope'] = 'R208 :: Inherited breast cancer and ovarian cancer'
    r208_r370_1_record.raw_fields['karyotypingmethod'] = 'R370.1 :: Confirmation of research result'
    r208_r370_1_record.raw_fields['genotype'] = 'BRCA1-GRCh38(chr17):g.43118884_43155545dup; (NM_007294.3):c.1100del-Heterozygous-UV3'
    @handler.add_test_scope_from_geno_karyo(@genotype, r208_r370_1_record)
    assert_equal 'Targeted BRCA mutation test', @genotype.attribute_map['genetictestscope']
    genotypes = @handler.process_variants_from_record(@genotype, r208_r370_1_record)
    assert_equal 1, genotypes.size
    assert_equal 2, genotypes[0].attribute_map['teststatus']
    assert_equal 7, genotypes[0].attribute_map['gene']
    assert_equal 'c.1100del', genotypes[0].attribute_map['codingdnasequencechange']
    assert_nil genotypes[0].attribute_map['proteinimpact']
  end

  private

  def clinical_json
    { sex: '1',
      consultantcode: 'Consultant Code',
      providercode: 'Provider Code',
      collecteddate: '2018-06-13T00:00:00.000+01:00',
      receiveddate: '2018-06-13T00:00:00.000+01:00',
      authoriseddate: '2018-07-04T00:00:00.000+01:00',
      servicereportidentifier: 'Service Report Identifier',
      sortdate: '2018-06-13T00:00:00.000+01:00',
      genetictestscope: 'BRCA1 and 2 gene analysis',
      karyotypingmethod: 'BRCA cDNA analysis',
      specimentype: '5',
      genotype: 'BRCA2: c.[520C>T];[520=]  p.[(?)];[(=)]',
      age: 63 }.to_json
  end

  def rawtext_clinical_json
    { sex: 'Male',
      servicereportidentifier: 'Service Report Identifier',
      providercode: 'Provider Address',
      consultantname: 'Consultant Name',
      patienttype: 'NHS',
      moleculartestingtype: 'Predictive testing',
      specimentype: 'Blood',
      collecteddate: '13/06/2018',
      receiveddate: '13/06/2018',
      authoriseddate: '04/07/2018',
      genotype: 'BRCA2: c.[520C>T];[520=]  p.[(?)];[(=)]',
      genetictestscope: 'BRCA1 and 2 gene analysis',
      karyotypingmethod: 'BRCA cDNA analysis' }.to_json
  end
end
