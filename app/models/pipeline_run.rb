require 'open3'
require 'json'
require 'csv'
class PipelineRun < ApplicationRecord
  include ApplicationHelper
  include PipelineOutputsHelper
  include PipelineRunsHelper
  belongs_to :sample
  belongs_to :alignment_config
  has_many :pipeline_run_stages
  accepts_nested_attributes_for :pipeline_run_stages
  has_and_belongs_to_many :backgrounds
  has_and_belongs_to_many :phylo_trees

  has_many :output_states
  has_many :taxon_counts, dependent: :destroy
  has_many :job_stats, dependent: :destroy
  has_many :taxon_byteranges, dependent: :destroy
  has_many :ercc_counts, dependent: :destroy
  has_many :amr_counts, dependent: :destroy
  has_many :contigs, dependent: :destroy
  has_many :contig_counts, dependent: :destroy
  accepts_nested_attributes_for :taxon_counts
  accepts_nested_attributes_for :job_stats
  accepts_nested_attributes_for :taxon_byteranges
  accepts_nested_attributes_for :ercc_counts
  accepts_nested_attributes_for :amr_counts
  accepts_nested_attributes_for :contigs
  accepts_nested_attributes_for :contig_counts

  DEFAULT_SUBSAMPLING = 1_000_000 # number of fragments to subsample to, after host filtering
  MAX_INPUT_FRAGMENTS = 75_000_000 # max fragments going into the pipeline
  ADAPTER_SEQUENCES = { "single-end" => "s3://idseq-database/adapter_sequences/illumina_TruSeq3-SE.fasta",
                        "paired-end" => "s3://idseq-database/adapter_sequences/illumina_TruSeq3-PE-2_NexteraPE-PE.fasta" }.freeze

  GSNAP_CHUNK_SIZE = 15_000
  RAPSEARCH_CHUNK_SIZE = 10_000
  GSNAP_MAX_CONCURRENT = 2
  RAPSEARCH_MAX_CONCURRENT = 6
  MAX_CHUNKS_IN_FLIGHT = 32

  GSNAP_M8 = "gsnap.m8".freeze
  RAPSEARCH_M8 = "rapsearch2.m8".freeze
  OUTPUT_JSON_NAME = 'taxon_counts.json'.freeze
  PIPELINE_VERSION_FILE = "pipeline_version.txt".freeze
  STATS_JSON_NAME = "stats.json".freeze
  ERCC_OUTPUT_NAME = 'reads_per_gene.star.tab'.freeze
  AMR_DRUG_SUMMARY_RESULTS = 'amr_summary_results.csv'.freeze
  AMR_FULL_RESULTS_NAME = 'amr_processed_results.csv'.freeze
  TAXID_BYTERANGE_JSON_NAME = 'taxid_locations_combined.json'.freeze
  REFINED_TAXON_COUNTS_JSON_NAME = 'assembly/refined_taxon_counts.json'.freeze
  REFINED_TAXID_BYTERANGE_JSON_NAME = 'assembly/refined_taxid_locations_combined.json'.freeze
  ASSEMBLED_CONTIGS_NAME = 'assembly/contigs.fasta'.freeze
  ASSEMBLED_STATS_NAME = 'assembly/contig_stats.json'.freeze
  CONTIG_SUMMARY_JSON_NAME = 'assembly/combined_contig_summary.json'.freeze
  CONTIG_NT_TOP_M8 = 'assembly/gsnap.blast.top.m8'.freeze
  CONTIG_NR_TOP_M8 = 'assembly/rapsearch2.blast.top.m8'.freeze
  CONTIG_MAPPING_NAME = 'assembly/contig2taxon_lineage.csv'.freeze
  ASSEMBLY_STATUSFILE = 'job-complete'.freeze
  LOCAL_JSON_PATH = '/app/tmp/results_json'.freeze
  LOCAL_AMR_FULL_RESULTS_PATH = '/app/tmp/amr_full_results'.freeze
  PIPELINE_VERSION_WHEN_NULL = '1.0'.freeze
  ASSEMBLY_PIPELINE_VERSION = 3.1
  MIN_CONTIG_SIZE = 4
  M8_FIELDS = ["Query", "Accession", "Percentage Identity", "Alignment Length",
               "Number of mismatches", "Number of gap openings",
               "Start of alignment in query", "End of alignment in query",
               "Start of alignment in accession", "End of alignment in accession",
               "E-value", "Bitscore"].freeze
  M8_FIELDS_TO_EXTRACT = [1, 2, 3, 4, 10, 11].freeze

  # The PIPELINE MONITOR is responsible for keeping status of AWS Batch jobs
  # and for submitting jobs that need to be run next.
  # It accomplishes this using the following:
  #    function "update_job_status"
  #    columns "job_status", "finalized"
  #    records "pipeline_run_stages".
  # The progression for a pipeline_run_stage's job_status is as follows:
  # STARTED -> RUNNABLE -> RUNNING -> SUCCEEDED / FAILED (via aegea batch or status files).
  # Once a stage has finished, the next stage is kicked off.
  # A pipeline_run's job_status indicates the most recent stage the run was at,
  # as well as that stage's status. At the end of a successful run, the pipeline_run's
  # job_status is set to CHECKED. If a late stage failed (e.g. postprocessing), but the
  # main report is ready, these facts are indicated in the job_status using the suffix
  # "FAILED|READY". The column "finalized", if set to 1, indicates that the pipeline monitor
  # no longer needs to check on or update the pipeline_run's job_status.

  STATUS_CHECKED = 'CHECKED'.freeze
  STATUS_FAILED = 'FAILED'.freeze
  STATUS_RUNNING = 'RUNNING'.freeze
  STATUS_RUNNABLE = 'RUNNABLE'.freeze
  STATUS_READY = 'READY'.freeze

  # The RESULT MONITOR is responsible for keeping status of available outputs
  # and for loading those outputs in from S3.
  # It accomplishes this using the following:
  #    function "monitor_results"
  #    column "results_finalized"
  #    records "output_states"
  # The output_states indicate the state of each target output, the progression being as follows:
  # UNKNOWN -> LOADING_QUEUED -> LOADING -> LOADED / FAILED (see also state machine below).
  # When all results have been loaded, or the PIPELINE MONITOR indicates no new outputs will be
  # forthcoming (due to either success or failure), results_finalized is set to FINALIZED_SUCCESS
  # or FINALIZED_FAIL in order to indicate to the RESULT MONITOR that it can stop attending to the pipeline_run.
  # In the case of failure, we determine whether the main report is nevertheless ready
  # by checking whether REPORT_READY_OUTPUT has been loaded.
  # Note we don't put a default on results_finalized in the schema, so that we can
  # recognize old runs by results_finalized being nil.

  STATUS_LOADED = 'LOADED'.freeze
  STATUS_UNKNOWN = 'UNKNOWN'.freeze
  STATUS_LOADING = 'LOADING'.freeze
  STATUS_LOADING_QUEUED = 'LOADING_QUEUED'.freeze
  STATUS_LOADING_ERROR = 'LOADING_ERROR'.freeze

  LOADERS_BY_OUTPUT = { "ercc_counts" => "db_load_ercc_counts",
                        "taxon_counts" => "db_load_taxon_counts",
                        "contig_counts" => "db_load_contig_counts",
                        "taxon_byteranges" => "db_load_byteranges",
                        "amr_counts" => "db_load_amr_counts" }.freeze
  # Note: reads_before_priceseqfilter, reads_after_priceseqfilter, reads_after_cdhitdup
  #       are the only "job_stats" we actually need for web display.
  REPORT_READY_OUTPUT = "taxon_counts".freeze

  # Values for results_finalized are as follows.
  # Note we don't put a default on results_finalized in the schema, so that we can
  # recognize old runs by results_finalized being nil.

  IN_PROGRESS = 0
  FINALIZED_SUCCESS = 10
  FINALIZED_FAIL = 20

  # State machine for RESULT MONITOR:
  #
  #  +-----------+ !output_ready
  #  |           | && !pipeline_finalized
  #  |           | (RM)
  #  |     +-----+------+
  #  +-----> POLLING    +------------------------------+
  #        +-----+------+                              |
  #              |                                     |
  #              | output_ready?                       |
  #              | (RM)                                |
  #              |                                     |
  #        +-----v------+                              |    !output_ready?
  #        | QUEUED FOR |                              |    && pipeline_finalized
  #        | LOADING    |                              |    (RM)
  #        +-----+------+                              |
  #              |                                     |
  #              | (Resque)                            |
  #              |                                     |
  #        +-----v------+         !success?            |
  #        | LOADING    +------------+                 |
  #        +-----+------+            |                 |
  #              |                   |(Resque          |
  #              | success?          |  Worker)        |
  #              | (Resque worker)   |                 |
  #        +-----v------+            |            +----v---+
  #        | COMPLETED  |            +------------> FAILED |
  #        +------------+                         +--------+
  #
  #
  # (RM) transition executed by the Result Monitor
  # (Resque Worker) transition executed by the Resque Worker

  # Constants for alignment chunk scheduling,
  # shared between idseq-web/app/jobs/autoscaling.py and idseq-dag/idseq_dag/util/server.py:
  MAX_JOB_DISPATCH_LAG_SECONDS = 900
  JOB_TAG_PREFIX = "RunningIDseqBatchJob_".freeze
  JOB_TAG_KEEP_ALIVE_SECONDS = 600
  DRAINING_TAG = "draining".freeze

  before_create :create_output_states, :create_run_stages

  def parse_dag_vars
    JSON.parse(dag_vars || "{}")
  end

  def as_json(options = {})
    super(options.merge(except: [:command, :command_stdout, :command_error, :job_description]))
  end

  def check_box_label
    project_name = sample.project ? sample.project.name : 'Unknown Project'
    "#{project_name} : #{sample.name} (#{id})"
  end

  def archive_s3_path
    "s3://#{SAMPLES_BUCKET_NAME}/pipeline_runs/#{id}_sample#{sample.id}"
  end

  def self.in_progress
    where("job_status != '#{STATUS_FAILED}' OR job_status IS NULL")
      .where(finalized: 0)
  end

  def self.results_in_progress
    where(results_finalized: IN_PROGRESS)
  end

  def self.in_progress_at_stage_1_or_2
    in_progress.where("job_status NOT LIKE '3.%' AND job_status NOT LIKE '4.%'")
  end

  def self.count_chunks(run_ids, known_num_reads, count_config, completed_chunks)
    chunk_size = count_config[:chunk_size]
    can_pair_chunks = count_config[:can_pair_chunks]
    is_run_paired = count_config[:is_run_paired]
    num_chunks_by_run_id = {}
    run_ids.each do |pr_id|
      # A priori, each run will count for 1 chunk
      num_chunks = 1
      # If number of non-host reads is known, we can compute the actual number of chunks from it
      if known_num_reads[pr_id]
        num_reads = known_num_reads[pr_id]
        if can_pair_chunks && is_run_paired[pr_id]
          num_reads /= 2.0
        end
        num_chunks = (num_reads / chunk_size.to_f).ceil
      end
      # If any chunks have already completed, we can subtract them
      num_chunks = [0, num_chunks - completed_chunks[pr_id]].max if completed_chunks[pr_id]
      # Due to rate limits in idseq-dag, there is a cap on the number of chunks dispatched concurrently by a single job
      num_chunks = [num_chunks, MAX_CHUNKS_IN_FLIGHT].min
      num_chunks_by_run_id[pr_id] = num_chunks
    end
    num_chunks_by_run_id.values.sum
  end

  def self.count_alignment_chunks_in_progress
    # Get run ids in progress
    need_alignment = in_progress_at_stage_1_or_2
    # Get numbers of non-host reads to estimate total number of chunks
    in_progress_job_stats = JobStat.where(pipeline_run_id: need_alignment.pluck(:id))
    last_host_filter_step = "subsampled_out"
    known_num_reads = Hash[in_progress_job_stats.where(task: last_host_filter_step).pluck(:pipeline_run_id, :reads_after)]
    # Determine which samples are paired-end to adjust chunk count
    runs_by_sample_id = need_alignment.index_by(&:sample_id)
    files_by_sample_id = InputFile.where(sample_id: need_alignment.pluck(:sample_id)).group_by(&:sample_id)
    is_run_paired = {}
    runs_by_sample_id.each do |sid, pr|
      is_run_paired[pr.id] = (files_by_sample_id[sid].count == 2)
    end
    # Get number of chunks that have already completed
    completed_gsnap_chunks = Hash[need_alignment.pluck(:id, :completed_gsnap_chunks)]
    completed_rapsearch_chunks = Hash[need_alignment.pluck(:id, :completed_rapsearch_chunks)]
    # Compute number of chunks that still need to be processed
    count_configs = {
      gsnap: {
        chunk_size: GSNAP_CHUNK_SIZE,
        can_pair_chunks: true, # gsnap can take paired inputs
        is_run_paired: is_run_paired
      },
      rapsearch: {
        chunk_size: RAPSEARCH_CHUNK_SIZE,
        can_pair_chunks: false # rapsearch always takes a single input file
      }
    }
    gsnap_num_chunks = count_chunks(need_alignment.pluck(:id), known_num_reads, count_configs[:gsnap], completed_gsnap_chunks)
    rapsearch_num_chunks = count_chunks(need_alignment.pluck(:id), known_num_reads, count_configs[:rapsearch], completed_rapsearch_chunks)
    { gsnap: gsnap_num_chunks, rapsearch: rapsearch_num_chunks }
  end

  def self.top_completed_runs
    where("id in (select max(id) from pipeline_runs where job_status = 'CHECKED' and
                  sample_id in (select id from samples) group by sample_id)")
  end

  def finalized?
    finalized == 1
  end

  def results_finalized?
    [FINALIZED_SUCCESS, FINALIZED_FAIL].include?(results_finalized)
  end

  def failed?
    /FAILED/ =~ job_status || results_finalized == FINALIZED_FAIL
  end

  def create_output_states
    # First, determine which outputs we need:
    target_outputs = %w[ercc_counts taxon_counts contig_counts taxon_byteranges amr_counts]

    # Then, generate output_states
    output_state_entries = []
    target_outputs.each do |output|
      output_state_entries << OutputState.new(
        output: output,
        state: STATUS_UNKNOWN
      )
    end
    self.output_states = output_state_entries

    # Also initialize results_finalized here.
    self.results_finalized = IN_PROGRESS
  end

  def create_run_stages
    run_stages = []

    # Host Filtering
    run_stages << PipelineRunStage.new(
      step_number: 1,
      name: PipelineRunStage::HOST_FILTERING_STAGE_NAME,
      job_command_func: 'host_filtering_command'
    )

    # Alignment and Merging
    run_stages << PipelineRunStage.new(
      step_number: 2,
      name: PipelineRunStage::ALIGNMENT_STAGE_NAME,
      job_command_func: 'alignment_command'
    )

    # Taxon Fastas and Alignment Visualization
    run_stages << PipelineRunStage.new(
      step_number: 3,
      name: PipelineRunStage::POSTPROCESS_STAGE_NAME,
      job_command_func: 'postprocess_command'
    )

    # Experimental Stage
    run_stages << PipelineRunStage.new(
      step_number: 4,
      name: PipelineRunStage::EXPT_STAGE_NAME,
      job_command_func: 'experimental_command'
    )

    self.pipeline_run_stages = run_stages
  end

  def completed?
    return true if finalized?
    # Old version before run stages
    return true if pipeline_run_stages.blank? && (job_status == STATUS_FAILED || job_status == STATUS_CHECKED)
  end

  def log_url
    return nil unless job_log_id
    "https://us-west-2.console.aws.amazon.com/cloudwatch/home?region=us-west-2" \
      "#logEventViewer:group=/aws/batch/job;stream=#{job_log_id}"
  end

  def active_stage
    pipeline_run_stages.order(:step_number).each do |prs|
      return prs unless prs.succeeded?
    end
    # If all stages have succeded:
    nil
  end

  def retry
    return unless failed? # only retry from a failed job
    prs = active_stage
    prs.job_status = nil
    prs.job_command = nil
    prs.db_load_status = 0
    prs.save
    self.finalized = 0
    self.results_finalized = IN_PROGRESS
    output_states.each { |o| o.update(state: STATUS_UNKNOWN) if o.state != STATUS_LOADED }
    save
  end

  def report_ready?
    os = output_states.find_by(output: REPORT_READY_OUTPUT)
    !os.nil? && os.state == STATUS_LOADED
  end

  def report_failed?
    # The report failed if host filtering or alignment failed.
    host_filtering_status = output_states.find_by(output: "ercc_counts").state
    alignment_status = output_states.find_by(output: "taxon_byteranges").state
    host_filtering_status == STATUS_FAILED || alignment_status == STATUS_FAILED
  end

  def succeeded?
    job_status == STATUS_CHECKED
  end

  def db_load_ercc_counts
    ercc_s3_path = "#{host_filter_output_s3_path}/#{ERCC_OUTPUT_NAME}"
    _stdout, _stderr, status = Open3.capture3("aws", "s3", "ls", ercc_s3_path)
    return unless status.exitstatus.zero?
    ercc_lines = Syscall.pipe(["aws", "s3", "cp", ercc_s3_path, "-"], ["grep", "ERCC"], ["cut", "-f1,2"])
    ercc_counts_array = []
    ercc_lines.split(/\r?\n/).each do |line|
      fields = line.split("\t")
      name = fields[0]
      count = fields[1].to_i
      ercc_counts_array << { name: name, count: count }
    end
    update(ercc_counts_attributes: ercc_counts_array)
    total_ercc_reads = ercc_counts_array.pluck(:count).sum * sample.input_files.count
    update(total_ercc_reads: total_ercc_reads)
  end

  def db_load_contigs(contig2taxid)
    contig_stats_s3_path = s3_file_for("contigs")
    contig_s3_path = "#{postprocess_output_s3_path}/#{ASSEMBLED_CONTIGS_NAME}"

    downloaded_contig_stats = PipelineRun.download_file_with_retries(contig_stats_s3_path,
                                                                     LOCAL_JSON_PATH, 3)
    contig_stats_json = JSON.parse(File.read(downloaded_contig_stats))
    return if contig_stats_json.empty?

    contig_fasta = PipelineRun.download_file_with_retries(contig_s3_path, LOCAL_JSON_PATH, 3)
    contig_array = []
    taxid_list = []
    contig2taxid.values.each { |entry| taxid_list += entry.values }
    taxon_lineage_map = {}
    TaxonLineage.where(taxid: taxid_list.uniq).order(:id).each { |t| taxon_lineage_map[t.taxid.to_i] = t.to_a }

    File.open(contig_fasta, 'r') do |cf|
      line = cf.gets
      header = ''
      sequence = ''
      while line
        if line[0] == '>'
          read_count = contig_stats_json[header] || 0
          lineage_json = get_lineage_json(contig2taxid[header], taxon_lineage_map)
          contig_array << { name: header, sequence: sequence, read_count: read_count, lineage_json: lineage_json.to_json } if header != ''
          header = line[1..line.size].rstrip
          sequence = ''
        else
          sequence += line
        end
        line = cf.gets
      end
      read_count = contig_stats_json[header] || 0
      lineage_json = get_lineage_json(contig2taxid[header], taxon_lineage_map)
      contig_array << { name: header, sequence: sequence, read_count: read_count, lineage_json: lineage_json.to_json }
    end
    contigs.destroy_all
    update(contigs_attributes: contig_array) unless contig_array.empty?
    update(assembled: 1)
  end

  def contigs_fasta_s3_path
    return "#{postprocess_output_s3_path}/#{ASSEMBLED_CONTIGS_NAME}" if pipeline_version && pipeline_version.to_f >= ASSEMBLY_PIPELINE_VERSION
  end

  def contigs_summary_s3_path
    return "#{postprocess_output_s3_path}/#{CONTIG_MAPPING_NAME}" if pipeline_version && pipeline_version.to_f >= ASSEMBLY_PIPELINE_VERSION
  end

  def get_lineage_json(ct2taxid, taxon_lineage_map)
    # Get the full lineage based on taxid
    # Sample output:
    # {"NT": [573,570,543,91347,1236,1224,-650,2, "Bacteria"],
    #  "NR": [573,570,543,91347,1236,1224,-650,2, "Bacteria"]}
    output = {}
    if ct2taxid
      ct2taxid.each { |count_type, taxid| output[count_type] = taxon_lineage_map[taxid.to_i] }
    end
    output
  end

  def get_m8_mapping(m8_file)
    m8_s3_path = "#{postprocess_output_s3_path}/#{m8_file}"
    m8_local_dir = "#{LOCAL_JSON_PATH}/#{id}"
    m8_local_path = PipelineRun.download_file_with_retries(m8_s3_path, m8_local_dir, 2)
    output = {}
    File.open(m8_local_path, 'r') do |m8f|
      line = m8f.gets
      while line
        fields = line.split("\t")
        output[fields[0]] = fields
        line = m8f.gets
      end
    end
    output
  end

  def generate_contig_mapping_table
    # generate a csv file for contig mapping based on lineage_json and top m8
    local_file_name = "#{LOCAL_JSON_PATH}/#{CONTIG_MAPPING_NAME}#{id}"
    Open3.capture3("mkdir -p #{File.dirname(local_file_name)}")
    # s3_file_name = contigs_summary_s3_path # TODO(yf): might turn back for s3 generation later
    nt_m8_map = get_m8_mapping(CONTIG_NT_TOP_M8)
    nr_m8_map = get_m8_mapping(CONTIG_NR_TOP_M8)
    CSV.open(local_file_name, 'w') do |writer|
      header_row = ['contig_name', 'read_count', 'contig_length', 'contig_coverage']
      header_row += TaxonLineage.names_a.map { |name| "NT.#{name}" }
      header_row += M8_FIELDS_TO_EXTRACT.map { |idx| "NT.#{M8_FIELDS[idx]}" }
      header_row += TaxonLineage.names_a.map { |name| "NR.#{name}" }
      header_row += M8_FIELDS_TO_EXTRACT.map { |idx| "NR.#{M8_FIELDS[idx]}" }
      writer << header_row
      contigs.each do |c|
        nt_m8 = nt_m8_map[c.name] || []
        nr_m8 = nr_m8_map[c.name] || []
        lineage = JSON.parse(c.lineage_json)
        row = [c.name, c.read_count]
        cfs = c.name.split("_")
        row += [cfs[3], cfs[5]]
        row += (lineage['NT'] || TaxonLineage.null_array)
        row += M8_FIELDS_TO_EXTRACT.map { |idx| nt_m8[idx] }
        row += (lineage['NR'] || TaxonLineage.null_array)
        row += M8_FIELDS_TO_EXTRACT.map { |idx| nr_m8[idx] }
        writer << row
      end
    end
    # Open3.capture3("aws s3 cp #{local_file_name} #{s3_file_name}")
    local_file_name
  end

  def db_load_contig_counts
    contig_stats_s3_path = s3_file_for("contig_counts")
    downloaded_contig_counts = PipelineRun.download_file_with_retries(contig_stats_s3_path,
                                                                      LOCAL_JSON_PATH, 3)
    contig_counts_json = JSON.parse(File.read(downloaded_contig_counts))
    contig_counts_array = []
    contig2taxid = {}
    contig_counts_json.each do |tax_entry|
      contigs = tax_entry["contig_counts"]
      contigs.each do |contig_name, count|
        contig_counts_array << { count_type: tax_entry['count_type'],
                                 taxid: tax_entry['taxid'],
                                 tax_level: tax_entry['tax_level'],
                                 contig_name: contig_name,
                                 count: count }
        if tax_entry['tax_level'].to_i == TaxonCount:: TAX_LEVEL_SPECIES # species
          contig2taxid[contig_name] ||= {}
          contig2taxid[contig_name][tax_entry['count_type']] = tax_entry['taxid']
        end
      end
    end
    contig_counts.destroy_all
    update(contig_counts_attributes: contig_counts_array) unless contig_counts_array.empty?
    db_load_contigs(contig2taxid)
  end

  def db_load_amr_counts
    amr_results = PipelineRun.download_file(s3_file_for("amr_counts"), local_amr_full_results_path)
    unless File.zero?(amr_results)
      amr_counts_array = []
      # First line of output file has header titles, e.g. "Sample/Gene/Allele..." that are extraneous
      # that we drop
      File.readlines(amr_results).drop(1).each do |amr_result|
        amr_result_fields = amr_result.split(",").drop(2)
        amr_counts_array << { gene: amr_result_fields[0],
                              allele: amr_result_fields[1],
                              coverage: amr_result_fields[2],
                              depth:  amr_result_fields[3],
                              drug_family: amr_result_fields[12] }
      end
      update(amr_counts_attributes: amr_counts_array)
    end
  end

  def taxon_counts_json_name
    OUTPUT_JSON_NAME
  end

  def invalid_family_call?(tcnt)
    # TODO:  Better family support.
    tcnt['family_taxid'].to_i < TaxonLineage::INVALID_CALL_BASE_ID
  rescue
    false
  end

  def load_taxons(downloaded_json_path, refined = false)
    json_dict = JSON.parse(File.read(downloaded_json_path))
    pipeline_output_dict = json_dict['pipeline_output']
    pipeline_output_dict.slice!('taxon_counts_attributes')

    # check if there's any record loaded into taxon_counts. If so, skip
    check_count_type = refined ? 'NT+' : 'NT'
    loaded_records = TaxonCount.where(pipeline_run_id: id)
                               .where(count_type: check_count_type).count
    return if loaded_records > 0

    # only keep counts at certain taxonomic levels
    taxon_counts_attributes_filtered = []
    acceptable_tax_levels = [TaxonCount::TAX_LEVEL_SPECIES]
    acceptable_tax_levels << TaxonCount::TAX_LEVEL_GENUS if multihit?
    acceptable_tax_levels << TaxonCount::TAX_LEVEL_FAMILY if multihit?
    pipeline_output_dict['taxon_counts_attributes'].each do |tcnt|
      # TODO:  Better family support.
      if acceptable_tax_levels.include?(tcnt['tax_level'].to_i) && !invalid_family_call?(tcnt)
        taxon_counts_attributes_filtered << tcnt
      end
    end
    # Set created_at and updated_at
    current_time = Time.now.utc # to match TaxonLineage date range comparison
    taxon_counts_attributes_filtered.each do |tcnt|
      tcnt["created_at"] = current_time
      tcnt["updated_at"] = current_time
      tcnt["count_type"] += "+" if refined
    end
    update(taxon_counts_attributes: taxon_counts_attributes_filtered)

    # aggregate the data at genus level
    generate_aggregate_counts('genus') unless multihit?
    # merge more accurate name information from lineages table
    update_names
    # denormalize superkingdom_taxid into taxon_counts
    if multihit?
      update_superkingdoms
    else
      update_genera
    end
    # label taxa as phage or non-phage
    update_is_phage

    # rm the json
    _stdout, _stderr, _status = Open3.capture3("rm -f #{downloaded_json_path}")
  end

  def db_load_taxon_counts
    output_json_s3_path = s3_file_for("taxon_counts")
    downloaded_json_path = PipelineRun.download_file_with_retries(output_json_s3_path,
                                                                  local_json_path, 3)
    LogUtil.log_err_and_airbrake("PipelineRun #{id} failed taxon_counts download") unless downloaded_json_path
    return unless downloaded_json_path
    load_taxons(downloaded_json_path, false)
  end

  def db_load_byteranges
    byteranges_json_s3_path = s3_file_for("taxon_byteranges")
    downloaded_byteranges_path = PipelineRun.download_file(byteranges_json_s3_path, local_json_path)
    taxon_byteranges_csv_file = "#{local_json_path}/taxon_byteranges"
    hash_array_json2csv(downloaded_byteranges_path, taxon_byteranges_csv_file, %w[taxid hit_type first_byte last_byte])
    Syscall.run_in_dir(local_json_path, "sed", "-e", "s/$/,#{id}/", "-i", "taxon_byteranges")
    Syscall.run_in_dir(local_json_path, "mysqlimport --user=$DB_USERNAME --host=#{rds_host} --password=$DB_PASSWORD --fields-terminated-by=',' --replace --local --columns=taxid,hit_type,first_byte,last_byte,pipeline_run_id idseq_#{Rails.env} taxon_byteranges")
    Syscall.run("rm", "-f", downloaded_byteranges_path)
  end

  def s3_file_for(output)
    case output
    when "ercc_counts"
      "#{host_filter_output_s3_path}/#{ERCC_OUTPUT_NAME}"
    when "amr_counts"
      "#{expt_output_s3_path}/#{AMR_FULL_RESULTS_NAME}"
    when "taxon_counts"
      if pipeline_version && pipeline_version.to_f >= ASSEMBLY_PIPELINE_VERSION
        "#{postprocess_output_s3_path}/#{REFINED_TAXON_COUNTS_JSON_NAME}"
      else
        "#{alignment_output_s3_path}/#{taxon_counts_json_name}"
      end
    when "taxon_byteranges"
      if pipeline_version && pipeline_version.to_f >= ASSEMBLY_PIPELINE_VERSION
        "#{postprocess_output_s3_path}/#{REFINED_TAXID_BYTERANGE_JSON_NAME}"
      else
        "#{postprocess_output_s3_path}/#{TAXID_BYTERANGE_JSON_NAME}"
      end
    when "contigs"
      "#{postprocess_output_s3_path}/#{ASSEMBLED_STATS_NAME}"
    when "contig_counts"
      "#{postprocess_output_s3_path}/#{CONTIG_SUMMARY_JSON_NAME}"
    end
  end

  def output_ready?(output)
    file_generated(s3_file_for(output))
  end

  def output_state_hash(output_states_by_pipeline_run_id)
    h = {}
    run_output_states = output_states_by_pipeline_run_id[id] || []
    run_output_states.each do |o|
      h[o.output] = o.state
    end
    h
  end

  def status_display(output_states_by_pipeline_run_id)
    status_display_helper(output_state_hash(output_states_by_pipeline_run_id), results_finalized)
  end

  def pre_result_monitor?
    results_finalized.nil?
  end

  def check_and_enqueue(output_state)
    # If the pipeline monitor tells us that no jobs are running anymore,
    # yet outputs are not available, we need to draw the conclusion that
    # those outputs should be marked as failed. Otherwise we will never
    # stop checking for them.
    # [ TODO: move the check on "finalized" (column managed by pipeline_monitor)
    #   to an S3 interface in order to give us the option of running pipeline_monitor
    #   in a new environment that result_monitor does not have access to.
    # ]
    output = output_state.output
    state = output_state.state
    return unless [STATUS_UNKNOWN, STATUS_LOADING_ERROR].include?(state)
    if output_ready?(output)
      output_state.update(state: STATUS_LOADING_QUEUED)
      Resque.enqueue(ResultMonitorLoader, id, output)
    elsif finalized? && pipeline_run_stages.order(:step_number).last.updated_at < 1.minute.ago
      # check if job is done more than a minute ago
      output_state.update(state: STATUS_FAILED)
    end
  end

  def load_stats_file
    stats_s3 = "#{output_s3_path_with_version}/#{STATS_JSON_NAME}"
    # TODO: Remove the datetime check?
    if file_generated_since_jobstats?(stats_s3)
      load_job_stats(stats_s3)
    end
  end

  def all_output_states_terminal?
    output_states.pluck(:state).all? { |s| [STATUS_LOADED, STATUS_FAILED].include?(s) }
  end

  def all_output_states_loaded?
    output_states.pluck(:state).all? { |s| s == STATUS_LOADED }
  end

  def monitor_results
    return if results_finalized?

    compiling_stats_failed = false

    # Get pipeline_version, which determines S3 locations of output files.
    # If pipeline version is not present, we cannot load results yet.
    # Except, if the pipeline run is finalized, we have to (this is a failure case).
    update_pipeline_version(self, :pipeline_version, pipeline_version_file)
    return if pipeline_version.blank? && !finalized

    # Load any new outputs that have become available:
    output_states.each do |o|
      check_and_enqueue(o)
    end

    # Update job stats:
    begin
      # TODO:  Make this less expensive while jobs are running, perhaps by doing it only sometimes, then again at end.
      # TODO:  S3 is a middleman between these two functions;  load_stats shouldn't wait for S3
      compile_stats_file
      load_stats_file
      load_chunk_stats
    rescue
      # TODO: Log this exception
      compiling_stats_failed = true
    end

    # Check if run is complete:
    if all_output_states_terminal?
      if all_output_states_loaded? && !compiling_stats_failed
        update(results_finalized: FINALIZED_SUCCESS)

        run_time = Time.current - created_at
        tags = ["sample_id:#{sample.id}"]
        MetricUtil.put_metric_now("samples.succeeded.run_time", run_time, tags, "gauge")
      else
        update(results_finalized: FINALIZED_FAIL)
      end
    end
  end

  def file_generated_since_jobstats?(s3_path)
    # If there is no file, return false
    stdout, _stderr, status = Open3.capture3("aws", "s3", "ls", s3_path.to_s)
    return false unless status.exitstatus.zero?
    # If there is a file and there are no existing job_stats yet, return true
    existing_jobstats = job_stats.first
    return true unless existing_jobstats
    # If there is a file and there are job_stats, check if the file supersedes the job_stats:
    begin
      s3_file_time = DateTime.strptime(stdout[0..18], "%Y-%m-%d %H:%M:%S")
      return (s3_file_time && existing_jobstats.created_at && s3_file_time > existing_jobstats.created_at)
    rescue
      return nil
    end
  end

  def load_job_stats(stats_json_s3_path)
    downloaded_stats_path = PipelineRun.download_file(stats_json_s3_path, local_json_path)
    return unless downloaded_stats_path
    stats_array = JSON.parse(File.read(downloaded_stats_path))
    stats_array = stats_array.select { |entry| entry.key?("task") }
    job_stats.destroy_all
    update(job_stats_attributes: stats_array)
    _stdout, _stderr, _status = Open3.capture3("rm -f #{downloaded_stats_path}")
  end

  def update_job_status
    prs = active_stage
    if prs.nil?
      # all stages succeeded
      self.finalized = 1
      self.job_status = STATUS_CHECKED
    else
      if prs.failed?
        self.job_status = STATUS_FAILED
        self.finalized = 1
        LogUtil.log_err_and_airbrake("SampleFailedEvent: Sample #{sample.id} failed #{prs.name}")
      elsif !prs.started?
        # we're moving on to a new stage
        prs.run_job
      else
        # still running
        prs.update_job_status
        # Check for long-running pipeline run and log/alert if needed
        check_and_log_long_run
      end
      self.job_status = "#{prs.step_number}.#{prs.name}-#{prs.job_status}"
      self.job_status += "|#{STATUS_READY}" if report_ready?
    end
    save
  end

  def job_status_display
    return "Pipeline Initializing" unless self.job_status
    stage = self.job_status.to_s.split("-")[0].split(".")[1]
    stage ? "Running #{stage}" : self.job_status
  end

  def check_and_log_long_run
    # Check for long-running pipeline runs and log/alert if needed:
    run_time = Time.current - created_at
    tags = ["sample_id:#{sample.id}"]
    MetricUtil.put_metric_now("samples.running.run_time", run_time, tags, "gauge")

    if alert_sent.zero?
      threshold = 5.hours
      if run_time > threshold
        duration_hrs = (run_time / 60 / 60).round(2)
        msg = "LongRunningSampleEvent: Sample #{sample.id} has been running for #{duration_hrs} hours."
        LogUtil.log_err_and_airbrake(msg)
        update(alert_sent: 1)
      end
    end
  end

  def load_chunk_stats
    stdout = Syscall.run("aws", "s3", "ls", "#{output_s3_path_with_version}/chunks/")
    return unless stdout
    outputs = stdout.split("\n").map { |line| line.split.last }
    gsnap_outputs = outputs.select { |file_name| file_name.start_with?("multihit-gsnap-out") && file_name.end_with?(".m8") }
    rapsearch_outputs = outputs.select { |file_name| file_name.start_with?("multihit-rapsearch2-out") && file_name.end_with?(".m8") }
    self.completed_gsnap_chunks = gsnap_outputs.length
    self.completed_rapsearch_chunks = rapsearch_outputs.length
    save
  end

  def compile_stats_file
    res_folder = output_s3_path_with_version
    stdout, _stderr, status = Open3.capture3("aws s3 ls #{res_folder}/ | grep count$")
    unless status.exitstatus.zero?
      return
    end

    # Compile all counts
    # Ex: [{"total_reads": 1122}, {"task": "star_out", "reads_after": 832}... {"adjusted_remaining_reads": 474}]
    all_counts = []
    stdout.split("\n").each do |line|
      fname = line.split(" ")[3] # Last col in line
      raw = Syscall.run("aws", "s3", "cp", "#{res_folder}/#{fname}", "-")
      contents = JSON.parse(raw)
      # Ex: {"gsnap_filter_out": 194}
      contents.each do |key, count|
        all_counts << { task: key, reads_after: count }
      end
    end

    # Load total reads
    total = all_counts.detect { |entry| entry.value?("fastqs") }
    if total
      all_counts << { total_reads: total[:reads_after] }
      self.total_reads = total[:reads_after]
    end

    # Load truncation
    truncation = all_counts.detect { |entry| entry.value?("truncated") }
    if truncation
      self.truncated = truncation[:reads_after]
    end

    # Load subsample fraction
    sub_before = all_counts.detect { |entry| entry.value?("bowtie2_out") }
    sub_after = all_counts.detect { |entry| entry.value?("subsampled_out") }
    frac = -1
    if sub_before && sub_after
      frac = (1.0 * sub_after[:reads_after]) / sub_before[:reads_after]
      all_counts << { fraction_subsampled: frac }
      self.fraction_subsampled = frac
    end

    # Load remaining reads
    # This is an approximation multiplied by the subsampled ratio so that it
    # can be compared to total reads for the user. Number of reads after host
    # filtering step vs. total reads as if subsampling had never occurred.
    rem = all_counts.detect { |entry| entry.value?("gsnap_filter_out") }
    if rem && frac != -1
      adjusted_remaining_reads = (rem[:reads_after] * (1 / frac)).to_i
      all_counts << { adjusted_remaining_reads: adjusted_remaining_reads }
      self.adjusted_remaining_reads = adjusted_remaining_reads
    else
      # gsnap filter is not done. use bowtie output as remaining reads
      bowtie = all_counts.detect { |entry| entry.value?("bowtie2_out") }
      if bowtie
        self.adjusted_remaining_reads = bowtie[:reads_after]
      end
    end

    # Load unidentified reads
    unidentified = all_counts.detect { |entry| entry.value?("unidentified_fasta") }
    if unidentified
      self.unmapped_reads = unidentified[:reads_after]
    end

    # Write JSON to a file
    tmp = Tempfile.new
    tmp.write(all_counts.to_json)
    tmp.close

    # Copy to S3. Overwrite if exists.
    _stdout, stderr, status = Open3.capture3("aws s3 cp #{tmp.path} #{res_folder}/#{STATS_JSON_NAME}")
    unless status.exitstatus.zero?
      Rails.logger.warn("Failed to write compiled stats file: #{stderr}")
    end

    save
  end

  def local_json_path
    "#{LOCAL_JSON_PATH}/#{id}"
  end

  def local_amr_full_results_path
    "#{LOCAL_AMR_FULL_RESULTS_PATH}/#{id}"
  end

  def local_amr_drug_summary_path
    "#{LOCAL_AMR_DRUG_SUMMARY_PATH}/#{id}"
  end

  def self.download_file_with_retries(s3_path, destination_dir, max_tries)
    round = 0
    while round < max_tries
      downloaded = PipelineRun.download_file(s3_path, destination_dir)
      return downloaded if downloaded
      round += 1
      sleep(15)
    end
  end

  def self.download_file(s3_path, destination_dir)
    command = "mkdir -p #{destination_dir};"
    command += "aws s3 cp #{s3_path} #{destination_dir}/;"
    _stdout, _stderr, status = Open3.capture3(command)
    return nil unless status.exitstatus.zero?
    "#{destination_dir}/#{File.basename(s3_path)}"
  end

  def file_generated(s3_path)
    _stdout, _stderr, status = Open3.capture3("aws", "s3", "ls", s3_path.to_s)
    status.exitstatus.zero?
  end

  def generate_aggregate_counts(tax_level_name)
    current_date = Time.now.utc.to_s(:db)
    tax_level_id = TaxonCount::NAME_2_LEVEL[tax_level_name]
    # The unctagorizable_name chosen here is not important. The report page
    # endpoint makes its own choice about what to display in this case.  It
    # has general logic to handle this and other undefined cases uniformly.
    # What is crucially important is the uncategorizable_id.
    uncategorizable_id = TaxonLineage::MISSING_LINEAGE_ID.fetch(tax_level_name.to_sym, -9999)
    uncategorizable_name = "Uncategorizable as a #{tax_level_name}"
    TaxonCount.connection.execute(
      "REPLACE INTO taxon_counts(pipeline_run_id, tax_id, name,
                                tax_level, count_type, count,
                                percent_identity, alignment_length, e_value,
                                species_total_concordant, genus_total_concordant, family_total_concordant,
                                percent_concordant, created_at, updated_at)
       SELECT #{id},
              IF(
                taxon_lineages.#{tax_level_name}_taxid IS NOT NULL,
                taxon_lineages.#{tax_level_name}_taxid,
                #{uncategorizable_id}
              ),
              IF(
                taxon_lineages.#{tax_level_name}_taxid IS NOT NULL,
                taxon_lineages.#{tax_level_name}_name,
                '#{uncategorizable_name}'
              ),
              #{tax_level_id},
              taxon_counts.count_type,
              sum(taxon_counts.count),
              sum(taxon_counts.percent_identity * taxon_counts.count) / sum(taxon_counts.count),
              sum(taxon_counts.alignment_length * taxon_counts.count) / sum(taxon_counts.count),
              sum(taxon_counts.e_value * taxon_counts.count) / sum(taxon_counts.count),
              /* We use AVG below because an aggregation function is needed, but all the entries being grouped are the same */
              AVG(species_total_concordant),
              AVG(genus_total_concordant),
              AVG(family_total_concordant),
              CASE #{tax_level_id}
                WHEN #{TaxonCount::TAX_LEVEL_SPECIES} THEN AVG(100.0 * taxon_counts.species_total_concordant) / sum(taxon_counts.count)
                WHEN #{TaxonCount::TAX_LEVEL_GENUS} THEN AVG(100.0 * taxon_counts.genus_total_concordant) / sum(taxon_counts.count)
                WHEN #{TaxonCount::TAX_LEVEL_FAMILY} THEN AVG(100.0 * taxon_counts.family_total_concordant) / sum(taxon_counts.count)
              END,
              '#{current_date}',
              '#{current_date}'
       FROM  taxon_lineages, taxon_counts
       WHERE (taxon_counts.created_at BETWEEN taxon_lineages.started_at AND taxon_lineages.ended_at) AND
             taxon_lineages.taxid = taxon_counts.tax_id AND
             taxon_counts.pipeline_run_id = #{id} AND
             taxon_counts.tax_level = #{TaxonCount::TAX_LEVEL_SPECIES}
      GROUP BY 1,2,3,4,5"
    )
  end

  def update_names
    # The names from the taxon_lineages table are preferred, but, not always
    # available;  this code merges them into taxon_counts.name.
    %w[species genus family].each do |level|
      level_id = TaxonCount::NAME_2_LEVEL[level]
      TaxonCount.connection.execute("
        UPDATE taxon_counts, taxon_lineages
        SET taxon_counts.name = taxon_lineages.#{level}_name,
            taxon_counts.common_name = taxon_lineages.#{level}_common_name
        WHERE taxon_counts.pipeline_run_id=#{id} AND
              taxon_counts.tax_level=#{level_id} AND
              taxon_counts.tax_id = taxon_lineages.taxid AND
              (taxon_counts.created_at BETWEEN taxon_lineages.started_at AND taxon_lineages.ended_at) AND
              taxon_lineages.#{level}_name IS NOT NULL
      ")
    end
  end

  def update_genera
    TaxonCount.connection.execute("
      UPDATE taxon_counts, taxon_lineages
      SET taxon_counts.genus_taxid = taxon_lineages.genus_taxid,
          taxon_counts.family_taxid = taxon_lineages.family_taxid,
          taxon_counts.superkingdom_taxid = taxon_lineages.superkingdom_taxid
      WHERE taxon_counts.pipeline_run_id=#{id} AND
            (taxon_counts.created_at BETWEEN taxon_lineages.started_at AND taxon_lineages.ended_at) AND
            taxon_lineages.taxid = taxon_counts.tax_id
    ")
  end

  def update_superkingdoms
    TaxonCount.connection.execute("
      UPDATE taxon_counts, taxon_lineages
      SET taxon_counts.superkingdom_taxid = taxon_lineages.superkingdom_taxid
      WHERE taxon_counts.pipeline_run_id=#{id}
            AND (taxon_counts.created_at BETWEEN taxon_lineages.started_at AND taxon_lineages.ended_at)
            AND taxon_counts.tax_id > #{TaxonLineage::INVALID_CALL_BASE_ID}
            AND taxon_lineages.taxid = taxon_counts.tax_id
    ")
    TaxonCount.connection.execute("
      UPDATE taxon_counts, taxon_lineages
      SET taxon_counts.superkingdom_taxid = taxon_lineages.superkingdom_taxid
      WHERE taxon_counts.pipeline_run_id=#{id}
            AND (taxon_counts.created_at BETWEEN taxon_lineages.started_at AND taxon_lineages.ended_at)
            AND taxon_counts.tax_id < #{TaxonLineage::INVALID_CALL_BASE_ID}
            AND taxon_lineages.taxid = MOD(ABS(taxon_counts.tax_id), ABS(#{TaxonLineage::INVALID_CALL_BASE_ID}))
    ")
  end

  def update_is_phage
    phage_families = TaxonLineage::PHAGE_FAMILIES_TAXIDS.join(",")
    TaxonCount.connection.execute("
      UPDATE taxon_counts
      SET is_phage = 1
      WHERE pipeline_run_id=#{id} AND
            family_taxid IN (#{phage_families})
    ")
    phage_taxids = TaxonLineage::PHAGE_TAXIDS.join(",")
    TaxonCount.connection.execute("
      UPDATE taxon_counts
      SET is_phage = 1
      WHERE pipeline_run_id=#{id} AND
            tax_id IN (#{phage_taxids})
    ")
  end

  def subsampled_reads
    # number of non-host reads that actually went through non-host alignment
    res = adjusted_remaining_reads
    if subsample
      # Ex: max of 1,000,000 or 2,000,000 reads
      max_reads = subsample * sample.input_files.count
      if adjusted_remaining_reads > max_reads
        res = max_reads
      end
    end
    res
    # 'subsample' is number of reads, respectively read pairs, to sample after host filtering
    # 'adjusted_remaining_reads' is number of individual reads remaining after subsampling
    # and host filtering, artificially multiplied to be at the original scale of total reads.
  end

  def subsample_fraction
    # fraction of non-host ("remaining") reads that actually went through non-host alignment
    if fraction_subsampled
      fraction_subsampled
    else # These should actually be the same value
      @cached_subsample_fraction ||= (1.0 * subsampled_reads) / adjusted_remaining_reads
    end
  end

  def subsample_suffix
    if pipeline_version && pipeline_version.to_f >= 2.0
      # New dag pipeline. no subsample folder
      return nil
    end
    all_suffix = pipeline_version ? "subsample_all" : ""
    subsample? ? "subsample_#{subsample}" : all_suffix
  end

  delegate :sample_output_s3_path, to: :sample

  # TODO: Refactor: "alignment_output_s3_path, postprocess_output_s3_path and
  # now expt_output_s3_path all contain essentially the same code.
  # So you could make a helper function to which you would pass
  #  sample.sample_expt_s3_path as an argument" (Charles)
  def expt_output_s3_path
    pipeline_ver_str = ""
    pipeline_ver_str = "#{pipeline_version}/" if pipeline_version
    result = "#{sample.sample_expt_s3_path}/#{pipeline_ver_str}#{subsample_suffix}"
    result.chomp("/")
  end

  def postprocess_output_s3_path
    pipeline_ver_str = ""
    pipeline_ver_str = "#{pipeline_version}/" if pipeline_version
    result = "#{sample.sample_postprocess_s3_path}/#{pipeline_ver_str}#{subsample_suffix}"
    result.chomp("/")
  end

  def alignment_viz_json_s3(taxon_info)
    # taxon_info example: 'nt.species.573'
    "#{alignment_viz_output_s3_path}/#{taxon_info}.align_viz.json"
  end

  def alignment_viz_output_s3_path
    "#{postprocess_output_s3_path}/align_viz"
  end

  def assembly_output_s3_path(taxid = nil)
    "#{postprocess_output_s3_path}/assembly/#{taxid}".chomp("/")
  end

  def host_filter_output_s3_path
    output_s3_path_with_version
  end

  def output_s3_path_with_version
    if pipeline_version
      "#{sample.sample_output_s3_path}/#{pipeline_version}"
    else
      sample.sample_output_s3_path
    end
  end

  def s3_paths_for_taxon_byteranges
    file_prefix = ''
    file_prefix = Sample::ASSEMBLY_PREFIX if pipeline_version && pipeline_version.to_f >= ASSEMBLY_PIPELINE_VERSION
    # by tax_level and hit_type
    { TaxonCount::TAX_LEVEL_SPECIES => {
      'NT' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA}",
      'NR' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA_NR}"
    },
      TaxonCount::TAX_LEVEL_GENUS => {
        'NT' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA_GENUS_NT}",
        'NR' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA_GENUS_NR}"
      },
      TaxonCount::TAX_LEVEL_FAMILY => {
        'NT' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA_FAMILY_NT}",
        'NR' => "#{postprocess_output_s3_path}/#{file_prefix}#{Sample::SORTED_TAXID_ANNOTATED_FASTA_FAMILY_NR}"
      } }
  end

  def pipeline_version_file
    "#{sample.sample_output_s3_path}/#{PIPELINE_VERSION_FILE}"
  end

  def major_minor(version)
    # given "1.5" return [1, 5]
    version.split('.').map(&:to_i)
  end

  def after(v0, v1)
    # Return "true" when v0 >= v1
    return true unless v1
    return false unless v0
    v0_major, v0_minor = major_minor(v0)
    v1_major, v1_minor = major_minor(v1)
    return true if v0_major > v1_major
    return false if v0_major < v1_major
    v0_minor >= v1_minor
  end

  def multihit?
    after(pipeline_version || fetch_pipeline_version, "1.5")
  end

  def assembly?
    after(pipeline_version, "1000.1000")
    # Very big version number so we don't accidentally start going into assembly mode.
    # Once we decide to deploy the assembly pipeline, change "1000.1000" to the relevant version number of idseq-pipeline.
  end

  def get_contigs_for_taxid(taxid, min_contig_size = MIN_CONTIG_SIZE)
    contig_names = contig_counts.where("count >= #{min_contig_size}")
                                .where(taxid: taxid)
                                .pluck(:contig_name).uniq
    contigs.where(name: contig_names).order("read_count DESC")
  end

  def get_taxid_list_with_contigs(min_contig_size = MIN_CONTIG_SIZE)
    contig_counts.where("count >= #{min_contig_size} and taxid > 0 and contig_name != '*'").pluck(:taxid).uniq
  end

  def alignment_output_s3_path
    pipeline_ver_str = ""
    pipeline_ver_str = "#{pipeline_version}/" if pipeline_version
    result = "#{sample.sample_output_s3_path}/#{pipeline_ver_str}#{subsample_suffix}"
    result.chomp("/")
  end

  delegate :project_id, to: :sample

  def compare_ercc_counts
    return nil if ercc_counts.empty?
    ercc_counts_by_name = Hash[ercc_counts.map { |a| [a.name, a] }]

    ret = []
    ErccCount::BASELINE.each do |baseline|
      actual = ercc_counts_by_name[baseline[:ercc_id]]
      actual_count = actual && actual.count || 0
      ret << {
        name: baseline[:ercc_id],
        actual: actual_count,
        expected: baseline[:concentration_in_mix_1_attomolesul]
      }
    end
    ret
  end

  def outputs_by_step(can_see_stage1_results = false)
    # Get map of s3 path to presigned URL and size.
    filename_to_info = {}
    sample.results_folder_files.each do |entry|
      filename_to_info[entry[:key]] = entry
    end
    # Get outputs and descriptions by target.
    result = {}
    pipeline_run_stages.each_with_index do |prs, stage_idx|
      next unless prs.dag_json && STEP_DESCRIPTIONS[prs.name]
      result[prs.name] = {
        "stage_description" => STEP_DESCRIPTIONS[prs.name]["stage"],
        "stage_dag_json" => prs.redacted_dag_json,
        "steps" => {}
      }
      dag_dict = JSON.parse(prs.dag_json)
      output_dir_s3_key = dag_dict["output_dir_s3"].chomp("/").split("/", 4)[3] # keep everything after bucket name, except trailing '/'
      targets = dag_dict["targets"]
      given_targets = dag_dict["given_targets"]
      num_steps = targets.length
      targets.each_with_index do |(target_name, output_list), step_idx|
        next if given_targets.keys.include?(target_name)
        file_info = []
        output_list.each do |output|
          file_info_for_output = filename_to_info["#{output_dir_s3_key}/#{pipeline_version}/#{output}"]
          next unless file_info_for_output
          if !can_see_stage1_results && stage_idx.zero? && step_idx < num_steps - 1
            # Delete URLs for all host-filtering outputs but the last, unless user uploaded the sample.
            file_info_for_output["url"] = nil
          end
          file_info << file_info_for_output
        end
        if file_info.present?
          result[prs.name]["steps"][target_name] = {
            "step_description" => STEP_DESCRIPTIONS[prs.name]["steps"][target_name],
            "file_list" => file_info
          }
        end
      end
    end
    # Get read counts (host filtering steps only)
    job_stats.each do |js|
      target_name = js.task
      result[target_name]["reads_after"] = js.reads_after if result.keys.include?(target_name)
    end
    result
  end

  def self.viewable(user)
    where(sample_id: Sample.viewable(user).pluck(:id))
  end
end
