require 'csv'
require 'json'
require 'net/http'

class DataciteUsageReportService
  attr_accessor :data_dir, :report, :list_of_files, :report_location

  class DataciteUsageReportException < StandardError
    def initialize(msg="MDR Datacite usage report service exception")
      super(msg)
    end
  end

  REPORT_ID = "NIMS-MDR-DATASET-REPORT"
  REPORT_NAME = "dataset report"
  REPORT_NAME_SHORT = "dsr"
  REPORT_NAME_RELEASE = "rd1"
  REPORT_CREATOR = "MDR"

  def initialize(start_date, end_date, data_dir, format: nil, report_location: "/data/data", save_report: false)
    raise DataciteUsageReportException.new("Cannot find #{data_dir}") unless Dir.exist?(data_dir)
    @report = {}
    @list_of_files = {}
    @start_date = start_date
    @end_date = end_date
    @data_dir = data_dir
    @data_dir = "#{data_dir}/" unless data_dir.end_with?("/")
    @report_location = report_location
    @report_location = "#{report_location}/" unless report_location.end_with?("/")
    @save_report = save_report
    begin
      if format
        @start_dt_parsed = Date.strptime(@start_date, format)
      else
        @start_dt_parsed = Date.parse(@start_date)
      end
    rescue
      raise DataciteUsageReportException.new("Cannot parse start date")
    end
    begin
      if format
        @end_dt_parsed = Date.strptime(@end_date, format)
      else
        @end_dt_parsed = Date.parse(@end_date)
      end
    rescue
      raise DataciteUsageReportException("Cannot parse end date")
    end
  end

  def generate_report(works=[])
    initialize_report
    add_report_datasets(works)
    write_report if @save_report
  end

  def write_report
    report_time = Time.now.strftime("%Y-%m-%dT%H-%M-%S")
    report_name = "datacite_usage_report-#{report_time}.json"
    File.open("#{@report_location}#{report_name}","w") do |f|
      f.write(JSON.pretty_generate(@report))
    end
  end

  def initialize_report
    @report = {
      "report-header" => {
        "report-name" => REPORT_NAME,
        "report-id" => REPORT_NAME_SHORT,
        "release" => REPORT_NAME_RELEASE,
        "created-by" => REPORT_CREATOR,
        "created" => Time.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reporting-period" => {
          "end-date" => @end_dt_parsed.strftime("%Y-%m-%d"),
          "begin-date" => @start_dt_parsed.strftime("%Y-%m-%d")
        }
      },
      "id" => REPORT_ID,
      "report-datasets" => []
    }
  end

  def add_report_datasets(works=[])
    @list_of_files = gather_files(works)
    @list_of_files.each do |work_key, files|
      work_key_parts = work_key.split('_', 2)
      work_type = "Publication"
      work_type = "Dataset" if work_key_parts[0] == 'dat'
      work_id = work_key_parts[1]
      add_each_report_dataset(files, work_id, work_type)
    end
  end

  def add_each_report_dataset(files, work_id, work_type)
    dataset_metrics = get_dataset_metrics(files)
    if dataset_metrics.size > 0
      dataset_report = get_dataset_metadata(files[0], work_id, work_type)
      dataset_report["performance"] = dataset_metrics
      @report["report-datasets"].append(dataset_report)
    end
  end

  def gather_files(works=[])
    csv_files = {}
    if works.present?
      works.each do |work_id|
        pattern =  "#{@data_dir}*/*#{work_id}*.csv"
        csv_files = csv_files.merge(gather_files_for_pattern(pattern))
      end
    else
      pattern = "#{@data_dir}*/*.csv"
      csv_files = csv_files.merge(gather_files_for_pattern(pattern))
    end
    csv_files.each do |work_key, files|
      csv_files[work_key] = sort_list_of_files(files)
    end
    csv_files
  end

  def sort_list_of_files(files)
    sorted_files = files.sort_by do |s|
      name_parts = File.basename(s, ".csv").split('_')
      name_date="#{name_parts[2]}-#{name_parts[3].rjust(2, '0')}-01"
      Date.strptime(name_date, "%Y-%m-%d")
    end
    sorted_files
  end

  def gather_files_for_pattern(pattern)
    csv_files = {}
    Dir.glob(pattern) {|filename|
      name_parts = File.basename(filename, ".csv").split('_')
      prefix = name_parts[0]
      work_id = name_parts[1]
      if file_in_range?(filename)
        csv_files["#{prefix}_#{work_id}"] ||= []
        csv_files["#{prefix}_#{work_id}"].append(filename)
      end
    }
    csv_files
  end

  def file_in_range?(filename)
    name_parts = File.basename(filename, ".csv").split('_')
    name_date="#{name_parts[2]}-#{name_parts[3].rjust(2, '0')}-01"
    dt = Date.strptime(name_date, "%Y-%m-%d")
    (@start_dt_parsed <= dt) && (dt <= @end_dt_parsed)
  end

  def get_dataset_metrics(files)
    # Total_Item_Requests, Total_Downloads_For_Item, Reporting period
    # 0, 0, 1-2024
    # Total_Item_Requests = total-dataset-investigations
    # Total_Downloads_For_Item = total-dataset-requests
    # "performance": [
    #         {
    #           "period": {
    #             "end-date": "2018-04-30",
    #             "begin-date": "2018-04-01"
    #           },
    #           "instance": [
    #             {
    #               "metric-type": "total-dataset-requests",
    #               "access-method": "regular"
    #             },
    #             {
    #               "count": 10,
    #               "metric-type": "total-dataset-investigations",
    #               "access-method": "regular"
    #             },
    #             {
    #               "count": 12,
    #               "metric-type": "unique-dataset-requests",
    #               "access-method": "regular"
    #             },
    #             {
    #               "count": 5,
    #               "metric-type": "unique-dataset-investigations",
    #               "access-method": "regular"
    #             }
    #           ]
    #         }
    #       ]
    metrics = []
    files.each do |csv_file|
      next unless File.exist?(csv_file)
      CSV.foreach(csv_file, headers: true) do |csv_row|
        row_hash = csv_row.to_h
        period = {}
        if row_hash.fetch("Reporting period", nil)
          date_parts = row_hash["Reporting period"].split('-')
          month = date_parts[0].rjust(2, "0")
          year = date_parts[1]
          start_date = "#{year}-#{month}-01"
          end_date = (Date.strptime(start_date, "%Y-%m-%d").next_month - 1).strftime("%Y-%m-%d")
          period = {
            "end-date" => end_date,
            "begin-date" => start_date
          }
        end
        views = fetch_count(row_hash, "views" )
        downloads = fetch_count(row_hash, "downloads")
        if (views.present? || downloads.present?) && period.present?
          metrics.append({
                               "period" => period,
                               "instance" => []
                             })
          metrics["instance"].append(views) if views.present?
          metrics["instance"].append(downloads) if downloads.present?
        end
      end
    end
    metrics
  end

  def get_dataset_metadata(csv_file, work_id, work_type)
    metadata = {}
    return metadata unless File.exist?(csv_file)
    CSV.foreach(csv_file, headers: true) do |csv_row|
      row_hash = csv_row.to_h
      # "uri": "https://cn.dataone.org/cn/v2/resolve/doi%3A10.5063%2FAA%2Fnceas.985.1",
      # URI
      if row_hash.fetch("URI", nil)
        metadata["uri"] ||= []
        metadata["uri"] = row_hash["URI"]
      end
      # "yop": "2010"
      # YOP
      if row_hash.fetch("YOP", nil)
        metadata["yop"] = row_hash["YOP"]
      end
      # "platform": "DataONE",
      if metadata.present?
        metadata["platform"] = REPORT_CREATOR
      end
      # "data-type": "dataset",
      data_type =  row_hash.fetch("Data_Type", work_type)
      metadata["data-type"] = data_type
      # "publisher": "DataONE",
      publisher = row_hash.fetch("publisher", "NIMS")
      metadata["publisher"] = publisher
      if publisher.strip.downcase == "nims"
        metadata["publisher-id"] = [
          {
            "type" => "grid",
            "value" => "grid.21941.3f"
          }
        ]
      end
      # "dataset-id": [
      #   {
      #     "value": "10.15146/R3J66V",
      #     "type": "doi"
      #   }
      # ]
      local_id = row_hash.fetch("Proprietary_ID", work_id)
      metadata["dataset-id"] ||= []
      metadata["dataset-id"].append({
                                      "type" => "Proprietary ID",
                                      "value" => local_id })
      if row_hash.fetch("DOI", nil)
        metadata["dataset-id"] ||= []
        metadata["dataset-id"].append({
                                        "type" => "doi",
                                        "value" => row_hash["DOI"].sub("https://doi.org/", "") })
      end
      # "dataset-dates": [
      #   {
      #     "type": "pub-date",
      #     "value": "2017-12-31"
      #   }
      # ]
      if row_hash.fetch("Publication_Date", nil)
        begin
          pub_date = Date.parse(row_hash["Publication_Date"]).strptime("%y-%m-%d")
        rescue
          pub_date = row_hash["Publication_Date"]
        end
        if pub_date
          metadata["dataset-dates"] ||= []
          metadata["dataset-dates"].append({"type" => "pub-date", "value" => pub_date })
        end
      end
      # "dataset-title": "Lake Erie Fish Community Data"
      # Title
      if row_hash.fetch("Title", nil)
        metadata["dataset-title"] = row_hash["Title"]
      end
      # "dataset-contributors": [
      #   {
      #     "type": "name",
      #     "value": "Cassandra Lopez"
      #   },
      #   {
      #     "type": "orcid",
      #     "value": "Cassandra Lopez"
      #   },
      #   {
      #     "type": "name",
      #     "value": "Cassandra Lopez"
      #   },
      #   {
      #     "type": "orcid",
      #     "value": "Cassandra Lopez"
      #   }
      # ]
      if row_hash.fetch("Authors", nil)
        metadata["dataset-contributors"] ||= []
        authors = row_hash["Authors"].split("|")
        authors.each do |author|
          metadata["dataset-contributors"].append({"type" => "name", "value" => author })
        end
      end
    end
    metadata
  end

  def fetch_count(row_hash, count_type)
    return {} unless %w[views downloads].include?(count_type)
    if count_type == "views"
      # Total_Item_Requests = total-dataset-investigations
      # {
      #   "count": 10,
      #   "metric-type": "total-dataset-investigations",
      #   "access-method": "regular"
      # },
      column_header = "Total_Item_Requests"
      metric_name = "total-dataset-investigations"
    else
      # Total_Downloads_For_Item = total-dataset-requests
      # {
      #   "count": 10,
      #   "metric-type": "total-dataset-requests",
      #   "access-method": "regular"
      # },
      column_header = "Total_Downloads_For_Item"
      metric_name = "total-dataset-requests"
    end
    metric = {}
    if row_hash.fetch(column_header, nil)
      begin
        requests_count =  row_hash[column_header].strip.to_i
      rescue
        requests_count = 0
      end
      if requests_count > 0
        metric = {
          "count" => requests_count,
          "metric-type" => metric_name,
          "access-method" => "regular"
        }
      end
    end
    metric
  end

  def send_report
    api_url = ENV.fetch('datacite_usage_report_api_endpoint', nil)
    api_token = ENV.fetch('datacite_usage_report_api_token', nil)
    no_api_url = "Environment variable datacite_usage_report_api_endpoint not set"
    no_api_token = "Environment variable datacite_usage_report_api_token not set"
    raise DataciteUsageReportException.new(no_api_url) unless api_url.present?
    raise DataciteUsageReportException.new(no_api_token) unless no_api_token.present?
    uri = URI(api_url)
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json; Accept: application/json'
    request['Authorization'] = "Bearer #{api_token}"

    request.body = @report.to_json

    request_options = {
      use_ssl: uri.scheme == 'https'
    }

    success = false
    response = Net::HTTP.start(uri.hostname, uri.port, request_options) do |http|
      http.request(request)
    end
    success = true if response.response.code.to_i.between?(200, 299)
    return success, response.body, response
  end

end

# ---------------------------
# Usage
# ---------------------------
# start_date = "2024-01-01"
# end_date = "2025-03-31"
# data_dir = "data/access_log"
# format = "%Y-%m-%d"
# report_location = "data/"
# works = [] # for all works
# works = ["7d278x37v"] # for specific work(s)
# d = DataciteUsageReportService.new(start_date, end_date, data_dir,
#                                    format: format,
#                                    report_location: report_location,
#                                    save_report: true)
# d.generate_report(works)
# success, response_body, response = d.send_report
