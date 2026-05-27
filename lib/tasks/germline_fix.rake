require 'csv'
require 'digest/sha1'
require 'fileutils'

namespace :germline do
  desc <<~USAGE
    Fix up a germline extract to remove duplicate entries from the CSV files
    Syntax: rake germline:remove_extract_duplicates export_dir=...
  USAGE
  task :remove_extract_duplicates do
    export_dir = ENV.fetch('export_dir')
    molecular_fn = File.join(export_dir, 'public.molecular_data_all.csv')
    genetic_test_results_fn = File.join(export_dir, 'public.genetic_test_results_all.csv')
    genetic_sequence_variants_fn = File.join(export_dir, 'public.genetic_sequence_variants_all.csv')
    molecular_ignore_cols = %w[molecular_dataid ppatient_id raw_record]
    genetic_test_results_ignore_cols = %w[genetictestresultid molecular_data_id raw_record]
    genetic_sequence_variants_ignore_cols = %w[geneticsequencevariantid genetic_test_result_id raw_record]

    puts "#{Time.current.to_fs(:db)} Preserving .orig versions of files"
    molecular_fn_orig = "#{molecular_fn}.orig"
    genetic_test_results_fn_orig = "#{genetic_test_results_fn}.orig"
    genetic_sequence_variants_fn_orig = "#{genetic_sequence_variants_fn}.orig"
    [[molecular_fn, molecular_fn_orig],
     [genetic_test_results_fn, genetic_test_results_fn_orig],
     [genetic_sequence_variants_fn, genetic_sequence_variants_fn_orig]].each do |fn, orig|
      FileUtils.cp(fn, orig, preserve: true, verbose: true) unless File.exist?(orig)
    end

    fingerprinter = lambda do |array|
      Digest::SHA1.hexdigest(array.join("\000"))
    end
    col_fingerprinter = lambda do |row, cols_to_keep|
      fingerprinter.call(cols_to_keep.collect { |col| row[col] })
    end

    # We aim to find genetic tests results with identical data, by building a structure
    # that identifies the fingerprints of the associarted genetic test results and
    # genetic sequence variants
    # Maps molecular_data_id => { genetic_test_resultid => [ fingerprint of genetic_test_result
    # row, fingerprints of any genetic_sequence_variants rows]
    molecular_data_fingerprints = {}
    # Maps genetictestresultid => molecular_data_id
    gtr_molecular_ids = {}
    puts "#{Time.current.to_fs(:db)} Fingerprinting #{File.basename(genetic_test_results_fn_orig)}"
    gtr_cols = nil
    CSV.foreach(genetic_test_results_fn_orig, headers: true) do |row|
      gtr_cols ||= row.headers - genetic_test_results_ignore_cols
      # This is a unique primary key, so there will only be 1 of each entry
      genetictestresultid = row['genetictestresultid']
      molecular_data_id = row['molecular_data_id']
      molecular_data_fingerprints[molecular_data_id] ||= {}
      molecular_data_fingerprints[molecular_data_id][genetictestresultid] =
        [col_fingerprinter.call(row, gtr_cols)]
      gtr_molecular_ids[genetictestresultid] = molecular_data_id
    end

    puts "#{Time.current.to_fs(:db)} Fingerprinting #{File.basename(genetic_sequence_variants_fn_orig)}"
    gsv_cols = nil
    CSV.foreach(genetic_sequence_variants_fn_orig, headers: true) do |row|
      gsv_cols ||= row.headers - genetic_sequence_variants_ignore_cols
      genetictestresultid = row['genetic_test_result_id']
      molecular_data_id = gtr_molecular_ids[genetictestresultid]
      molecular_data_fingerprints[molecular_data_id][genetictestresultid] <<
        col_fingerprinter.call(row, gsv_cols)
    end
    gtr_molecular_ids = nil # Release memory

    puts "#{Time.current.to_fs(:db)} Flattening molecular_data fingerprints"
    # Flatten molecular_data fingerprints, ignoring geneticrestresultid values
    molecular_data_flat = molecular_data_fingerprints.transform_values do |gtrs|
      gsv_unified_fingerprints = gtrs.collect do |_genetictestresultid, row_fingerprints|
        fingerprinter.call(row_fingerprints.uniq)
      end
      fingerprinter.call(gsv_unified_fingerprints.sort)
    end
    # molecular_data_fingerprints = nil # Release memory

    puts "#{Time.current.to_fs(:db)} Filtering #{File.basename(molecular_fn_orig)}"
    molecular_data = CSV.read(molecular_fn_orig, headers: true)
    cols = molecular_data[0].headers - molecular_ignore_cols
    grouped = molecular_data.group_by do |row|
      molecular_dataid = row['molecular_dataid']
      unless molecular_data_flat[molecular_dataid]
        puts "Warning: No genetic_tests_results for molecular_dataid #{molecular_dataid}"
      end
      cols.collect { |col| row[col] } + [molecular_data_flat[molecular_dataid] || '']
    end

    puts "#{Time.current.to_fs(:db)} Rewriting #{File.basename(molecular_fn)}"
    molecular_dataids_to_keep = Set.new
    File.open(molecular_fn, 'w') do |f|
      f << molecular_data[0].headers.to_csv
      grouped.each_value do |rows|
        f << rows[0].to_csv
        molecular_dataids_to_keep << rows[0]['molecular_dataid']
      end
    end
    puts "Keeping #{molecular_dataids_to_keep.size} molecular_dataids"

    puts "#{Time.current.to_fs(:db)} Rewriting #{File.basename(genetic_test_results_fn)}"
    genetictestresultids_to_keep = Set.new
    File.open(genetic_test_results_fn, 'w') do |f|
      CSV.foreach(genetic_test_results_fn_orig, headers: true).with_index do |row, i|
        f << row.headers.to_csv if i.zero?
        molecular_data_id = row['molecular_data_id']
        next unless molecular_dataids_to_keep.include?(molecular_data_id)

        f << row.to_csv
        genetictestresultids_to_keep << row['genetictestresultid']
      end
    end

    puts "Keeping #{genetictestresultids_to_keep.size} genetictestresultids"
    puts "#{Time.current.to_fs(:db)} Rewriting #{File.basename(genetic_sequence_variants_fn)}"
    File.open(genetic_sequence_variants_fn, 'w') do |f|
      CSV.foreach(genetic_sequence_variants_fn_orig, headers: true).with_index do |row, i|
        f << row.headers.to_csv if i.zero?
        genetictestresultid = row['genetic_test_result_id']
        next unless genetictestresultids_to_keep.include?(genetictestresultid)

        f << row.to_csv
      end
    end

    puts "#{Time.current.to_fs(:db)} Done"
    puts "Extracted #{grouped.size} unique molecular_data rows out of #{molecular_data.size} rows"
  end
end

=begin
# bash commands to check lookup consistency
(
  echo "1. Checking .csv.orig files for reference consistency"
  echo "Checking molecular_dataids (expect no '<' entries below)"
  echo "'>' entries mean data in molecular_data but not in genetic_test_results"
  diff --minimal \
    <(csvcut -z 600000 -c molecular_dataid 'public.molecular_data_all.csv.orig' | tail -n+2 | sort) \
    <(csvcut -z 600000 -c molecular_data_id 'public.genetic_test_results_all.csv.orig' | tail -n+2 | sort -u ) \
    | cut -c1 | grep '^[<>]' | sort | uniq -c

  echo "Checking genetic_test_resultids (expect no '<' entries below)"
  echo "'>' entries mean data in genetic_test_results but not in genetic_sequence_variants"
  diff --minimal \
    <(csvcut -z 600000 -c genetictestresultid 'public.genetic_test_results_all.csv.orig' | tail -n+2 | sort) \
    <(csvcut -z 600000 -c genetic_test_result_id 'public.genetic_sequence_variants_all.csv.orig' | \
        tail -n+2 | sort -u ) \
    | cut -c1 | grep '^[<>]' | sort | uniq -c

  echo
  echo "2. Checking .csv files for reference consistency"
  echo "Checking molecular_dataids (expect no '<' entries below)"
  echo "'>' entries mean data in molecular_data but not in genetic_test_results"
  diff --minimal \
    <(csvcut -z 600000 -c molecular_dataid 'public.molecular_data_all.csv' | tail -n+2 | sort) \
    <(csvcut -z 600000 -c molecular_data_id 'public.genetic_test_results_all.csv' | tail -n+2 | sort -u ) \
    | cut -c1 | grep '^[<>]' | sort | uniq -c

  echo "Checking genetic_test_resultids (expect no '<' entries below)"
  echo "'>' entries mean data in genetic_test_results but not in genetic_sequence_variants"
  diff --minimal \
    <(csvcut -z 600000 -c genetictestresultid 'public.genetic_test_results_all.csv' | tail -n+2 | sort) \
    <(csvcut -z 600000 -c genetic_test_result_id 'public.genetic_sequence_variants_all.csv' | tail -n+2 | sort -u ) \
    | cut -c1 | grep '^[<>]' | sort | uniq -c

  echo
  echo "3. Checking diffs to ensure that rows have simply been deleted"
  echo "Checking public.molecular_data_all.csv{.orig,} (expect no '>' entries below)"
  echo "'<' entries mean duplicate data has been removed"
  diff --minimal public.molecular_data_all.csv{.orig,} |cut -c1 |grep '^[<>]'|sort |uniq -c

  echo "Checking public.genetic_test_results_all.csv{.orig,} (expect no '>' entries below)"
  echo "'<' entries mean duplicate data has been removed"
  diff --minimal public.genetic_test_results_all.csv{.orig,} |cut -c1 |grep '^[<>]'|sort |uniq -c

  echo "Checking public.genetic_sequence_variants_all.csv{.orig,} (expect no '>' entries below)"
  echo "'<' entries mean duplicate data has been removed"
  diff --minimal public.genetic_sequence_variants_all.csv{.orig,} |cut -c1 |grep '^[<>]'|sort |uniq -c
  echo Done
)
=end
