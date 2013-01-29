%MAIN_GLIDER_DATA_PROCESSING_NRT  Run near real time glider processing chain.
%
%  This script develops the full processing chain for real time glider data:
%    - Check for active deployments from deployment information source.
%    - Download new or updated deployment raw data files.
%    - Convert downloaded files to human readable format if needed.
%    - Load data from all files in a single and consistent structure.
%    - Preprocess raw data applying simple unit conversions data without 
%      modifying it:
%      01. NMEA latitude and longitude to decimal degrees.
%    - Generate standarized product version of raw data (NetCDF level 0).
%    - Process raw data to obtain well referenced trajectory data with new 
%      derived measurements and corrections. The following steps are applied:
%      01. Select reference sensors for time and space coordinates.
%      02. Select extra navigation sensors: commanded waypoints, pitch, depth...
%      03. Select sensors of interest: CTD, oxygen, ocean color...
%      04. Identify transect boundaries at waypoint changes.
%      05. Identify cast boundaries from vertical direction changes.
%      06. General sensor processings: sensor lag correction, interpolation...
%      07. Process CTD data: pressure filtering, thermal lag correction...
%      08. Derive new measurements: depth, salinity, density, ...
%    - Generate standarized product version of trajectory data (NetCDF level 1).
%    - Interpolate trajectory data to obtain gridded data (vertical 
%      instantaneous profiles of already processed data).
%    - Generate standarized product version of gridded data (NetCDF level 2).
%    - Generate descriptive figures of both trajectory and gridded data.
%
%  See also:
%
%  Notes:
%    This script is based on the previous work by Tomeu Garau. He is the true
%    glider man.
%
%  Author: Joan Pau Beltran
%  Email: joanpau.beltran@socib.cat


%% Configure toolbox and configuration file path.
glider_toolbox_dir = configGliderToolboxPath();


%% Configure deployment data paths.
config.local_paths = configRTLocalPaths();
config.public_paths = configRTPublicPaths();


%% Configure NetCDF output.
config.output_ncl0 = configRTOutputNetCDFL0();
config.output_ncl1 = configRTOutputNetCDFL1();
config.output_ncl2 = configRTOutputNetCDFL2();


%% Set the path to the data: edit for mission processing.
%{
output_dirs.image_base_local_path = '/home/jbeltran/public_html/glider';
output_dirs.imageBaseURLPath    = 'http://www.socib.es/~jbeltran/glider/web';
%}


%% Configure processing options.
config.preprocessing_options = configPreprocessingOptions();
config.processing_options = configProcessingOptions();
config.gridding_options = configGriddingOptions();


%% Configure data base deployment information source.
config.db_access = configDBAccess();
[config.db_query, config.db_fields] = configRTDeploymentInfoQuery();


%% Configure Slocum file downloading and conversion, and Slocum data loading.
config.slocum_options = configRTSlocumFileOptions();


%% Configure dockserver glider data source.
config.dockservers = configDockservers();


%% Get list of deployments to process from database.
disp('Querying information of glider deployments...');
deployment_list = ...
  getDBDeploymentInfo(config.db_access, config.db_query, config.db_fields);
deployment_list = deployment_list([deployment_list.deployment_id] == 99);
if isempty(deployment_list)
  disp('No active glider deployments available.');
  return
else
  disp(['Active deployments found: ' num2str(numel(deployment_list)) '.']);
end


%% Process active deployments.
for deployment_idx = 1:numel(deployment_list)
  %% Set deployment field shortcut variables.
  disp(['Processing deployment ' num2str(deployment_idx) ' ...']);
  deployment = deployment_list(deployment_idx);
  deployment_name = deployment.deployment_name;
  deployment_id = deployment.deployment_id;
  deployment_start = deployment.deployment_start;
  deployment_end = deployment.deployment_end;
  glider_name = deployment.glider_name;
  binary_dir = strfglider(config.local_paths.binary_path, deployment);
  cache_dir = strfglider(config.local_paths.cache_path, deployment);
  log_dir = strfglider(config.local_paths.log_path, deployment);
  ascii_dir = strfglider(config.local_paths.ascii_path, deployment);
  figure_dir = strfglider(config.local_paths.figure_path, deployment);
  disp('Deployment information:')
  disp(['  Glider name          : ' glider_name]);
  disp(['  Deployment identifier: ' num2str(deployment_id)]);
  disp(['  Deployment name      : ' deployment_name]);
  disp(['  Deployment start     : ' datestr(deployment_start)]);
  if isempty(deployment_end)
    disp(['  Deployment end       : ' 'undefined']);
  else
    disp(['  Deployment end       : ' datestr(deployment_end)]);
  end

    
  %% Download deployment glider files from station(s).
  % Check for new or updated deployment files in every dockserver.
  % Deployment start time must be truncated to days because the date of 
  % a binary file is deduced from its name only up to day precission.
  % Deployment end time may be undefined.
  disp('Downloading deployment new data...');
  download_start = datenum(datestr(deployment_start,'yyyy-mm-dd'),'yyyy-mm-dd');
  if isempty(deployment_end)
    download_end = posixtime2utc(posixtime());
  else
    download_end = deployment_end;
  end
  new_xbds = cell(size(config.dockservers));
  new_logs = cell(size(config.dockservers));
  for dockserver_idx = 1:numel(config.dockservers)
    dockserver = config.dockservers(dockserver_idx);
    try
      [new_xbds{dockserver_idx}, new_logs{dockserver_idx}] = ...
        getDockserverFiles(dockserver, glider_name, binary_dir, log_dir, ...
                           'start', download_start, 'end', download_end, ...
                           'bin_name', config.slocum_options.bin_name_pattern, ...
                           'log_name', config.slocum_options.log_name_pattern);
    catch exception
      disp(['Error getting dockserver files from ' dockserver.host ':']);
      disp(getReport(exception, 'extended'));
    end
  end  
  new_xbds = [new_xbds{:}];
  new_logs = [new_logs{:}];
  disp(['Binary data files downloaded: '  num2str(numel(new_xbds)) '.']);
  disp(['Surface log files downloaded: '  num2str(numel(new_logs)) '.']);
  
  
  %% Convert binary glider files to ascii human readable format.
  % For each downloaded binary file, convert it to ascii format in the ascii
  % directory and store the returned absolute path for use later.
  % Since some conversion may fail use a cell array of string cell arrays and
  % flatten it when finished, leaving only the succesfully created dbas.
  disp('Converting binary data files to ascii format...');
  new_dbas = cell(size(new_xbds));
  for xbd_idx = 1:numel(new_xbds)
    xbd_fullfile = new_xbds{xbd_idx};
    [~, xbd_name, xbd_ext] = fileparts(xbd_fullfile);
    xbd_name_ext = [xbd_name xbd_ext];
    dba_name_ext = regexprep(xbd_name_ext, ...
                             config.slocum_options.bin_name_pattern, ...
                             config.slocum_options.dba_name_replacement); 
    dba_fullfile = fullfile(ascii_dir, dba_name_ext);
    try
      new_dbas{xbd_idx} = {xbd2dba(xbd_fullfile, dba_fullfile, 'cache', cache_dir)};
    catch exception
      disp(['Error converting binary file ' xbd_name_ext ':']);
      disp(getReport(exception, 'extended'));
      new_dbas{xbd_idx} = {};
    end
  end
  new_dbas = [new_dbas{:}];
  disp(['Binary files converted: ' ...
        num2str(numel(new_dbas)) ' of ' num2str(numel(new_xbds)) '.']);

%{
  %% Quit deployment processing if there is no new data.
  if isempty(new_dbas)
    disp('No new deployment data, skipping data processing and product generation.');
    continue
  end
%}  
  
  %% Load data from ascii deployment glider files.
  disp('Loading raw deployment data from text files...');
  try
    load_start = deployment_start;
    if isempty(deployment_end)
      load_end = posixtime2utc(posixtime());
    else
      load_end = deployment_end;
    end
    [meta_raw, data_raw] = ...
      loadSlocumData(ascii_dir, ...
                     config.slocum_options.dba_name_pattern_nav, ...
                     config.slocum_options.dba_name_pattern_sci, ...
                     'timestamp_nav', config.slocum_options.dba_time_sensor_nav, ...
                     'timestamp_sci', config.slocum_options.dba_time_sensor_sci, ...
                     'sensors', config.slocum_options.dba_sensors, ...
                     'period', [load_start load_end], ...
                     'format', 'struct');
  catch exception
    disp('Error loading Slocum data:');
    disp(getReport(exception, 'extended'));
    disp(['Deployment ' num2str(deployment_id) ' processing aborted!']);
    continue
  end
  disp(['Slocum files loaded: ' num2str(numel(meta_raw.sources)) '.']);
  
  
  %% Add source files to deployment structure.
  deployment.source_files = sprintf('%s\n', meta_raw.headers.filename_label);
  
  
  %% Preprocess raw glider data.
  disp('Preprocessing raw data...');
  try
    data_preprocessed = ...
      preprocessGliderData(data_raw, config.preprocessing_options);
  catch exception
    disp('Error preprocessing raw data:');
    disp(getReport(exception, 'extended'));
    disp(['Deployment ' num2str(deployment_id) ' processing aborted!']);
    continue
  end
  
  
  %% Generate L0 NetCDF file (raw/preprocessed data), if needed.
  outputs.netcdf_l0 = [];
  if isfield(config.local_paths, 'netcdf_l0') && ~isempty(config.local_paths.netcdf_l0)
    disp('Generating NetCDF L0 output...');
    ncl0_file = strfglider(config.local_paths.netcdf_l0, deployment);
    try
      outputs.netcdf_l0 = ...
        generateOutputNetCDFL0(ncl0_file, data_preprocessed, ...
                               config.output_ncl0.var_meta, ...
                               config.output_ncl0.dim_names, ...
                               config.output_ncl0.global_atts, deployment);
    disp(['Output NetCDF L0 (raw data) generated: ' output_ncl0 '.']);
    catch exception
      disp(['Error generating NetCDF L0 (preprocessed data) output ' ncl0_file ':']);
      disp(getReport(exception, 'extended'));
    end;
  end
  
  
  %% Process preprocessed glider data.
  disp('Processing glider data...');
  try
    data_processed = ...
      processGliderData(data_preprocessed, config.processing_options);
  catch exception
    disp('Error processing glider deployment data:');
    disp(getReport(exception, 'extended'));
    disp(['Deployment ' num2str(deployment_id) ' processing aborted!']);
    continue
  end
  
  
  %% Generate L1 NetCDF file (processed data).
  outputs.netcdf_l1 = [];
  if isfield(config.local_paths, 'netcdf_l1') && ~isempty(config.local_paths.netcdf_l1)
    disp('Generating NetCDF L1 output...');
    ncl1_file = strfglider(config.local_paths.netcdf_l1, deployment);
    try
      outputs.netcdf_l1 = ...
        generateOutputNetCDFL1(ncl1_file, data_processed, ...
                               config.output_ncl1.var_meta, ...
                               config.output_ncl1.dim_names, ...
                               config.output_ncl1.global_atts, deployment);
      disp(['Output NetCDF L1 (processed data) generated: ' outputs.netcdf_l1 '.']);
    catch exception
      disp(['Error generating NetCDF L1 (processed data) output ' ncl1_file ':']);
      disp(getReport(exception, 'extended'));
    end;
  end
  
  
  %% Process glider trajectory data to vertically gridded data.
  disp('Gridding glider data...');
  try
    data_gridded = gridGliderData(data_processed, config.gridding_options);
  catch exception
    disp('Error processing glider deployment data:');
    disp(getReport(exception, 'extended'));
    disp(['Deployment ' num2str(deployment_id) ' processing aborted!']);
    continue
  end
  
  
  %% Generate L2 (gridded data) netcdf file.
  outputs.netcdf_l2 = [];
  if isfield(config.local_paths, 'netcdf_l2') && ~isempty(config.local_paths.netcdf_l2)
    disp('Generating NetCDF L2 output...');
    ncl2_file = strfglider(config.local_paths.netcdf_l2, deployment);
    try
      outputs.netcdf_l2 = ...
        generateOutputNetCDFL2(ncl2_file, data_gridded, ...
                               config.output_ncl2.var_meta, ...
                               config.output_ncl2.dim_names, ...
                               config.output_ncl2.global_atts, deployment);
      disp(['Output NetCDF L2 (gridded data) generated: ' outputs.netcdf_l2 '.']);
    catch exception
      disp(['Error generating NetCDF L2 (gridded data) output ' ncl2_file ':']);
      disp(getReport(exception, 'extended'));
    end
  end
  
  
  %% Copy selected products to corresponding public location, if needed.
  disp('Copying public outputs...');
  output_list = {'netcdf_l0', 'netcdf_l1', 'netcdf_l2'};
  for output_idx = 1:numel(output_list)
    output = output_list{output_idx};
    if isfield(config.public_paths, output) ...
         && ~isempty(config.public_paths.(output)) ...
         && ~isempty(outputs.(output))
      output_local_file = outputs.(output);
      output_public_file = strfglider(config.public_paths.(output), deployment);
      output_public_dir = fileparts(output_public_file);
      if ~isdir(output_public_dir)
        [success, message] = mkdir(output_public_dir);
        if ~success
          disp(['Error creating public directory for deployment product ' ...
                output ': ' output_public_dir '.']);
          disp(message);
          continue
        end
      end
      [success, message] = copyfile(output_local_file, output_public_file);
      if success
        disp(['Public output ' output ' succesfully created: ' output_public_file '.']);
      else
        disp(['Error creating public copy of deployment product ' output ': ' output_public_file '.']);
        disp(message);
      end
    end
  end
  
  
  %% Generate deployment figures.
  %{
  try
    %{
    for transect_start = 1:length(processed_data.transects) - 1
      [partial_processed_data, partial_gridded_data] = ...
      trimGliderData(processed_data, gridded_data, ...
      [processed_data.transects(transect_start), ...
      processed_data.transects(transect_start + 1)]);
      transect_image_dir = fullfile(image_dir, ['transect', num2str(transect_start)]);
      mkdir(transect_image_dir);
      imgs_list = generateScientificFigures(partial_processed_data, partial_gridded_data, transect_image_dir, [glider_name, '_']);
    end;
    %}
    imgs_list = generateScientificFigures(processed_data, gridded_data, ...
                                          figure_dir, [glider_name, '_']);
    % Add URL base path to images
    for idx = 1:length(imgs_list)
      imgs_list(idx).path = fullfile(output_dirs.imageBaseURLPath, ...
                                     glider_name, deployment_name, ...
                                     imgs_list(idx).path);
    end
    json_name = fullfile(output_dirs.image_base_local_path, ...
                         [glider_name '.' deployment_name '.images.json']);
    writeJSON(imgs_list, json_name);
  catch exception
    disp('Error generating scientific figures:');
    disp(getReport(exception, 'extended'));
  end
  %}
  
end
