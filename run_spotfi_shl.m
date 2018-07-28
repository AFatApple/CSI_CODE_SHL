function output_top_aoas = run_spotfi_shl(filepath)
	antenna_distance = 0.026;
    frequency = 5.745 * 10^9; 
    sub_freq_delta = (20 * 10^6) / 30;
    plot_switch = 0;
	csi_trace=readfile(filepath);
    %csi_rss=get_total_rss(csi_trace{5});
    csi_rss=get_total_RSS_SHL(csi_trace);
    num_packets = floor(length(csi_trace)/30);
	sampled_csi_trace = csi_sampling(csi_trace, num_packets, 1, length(csi_trace));
 	[aoa_packet_data, tof_packet_data] = run_music(sampled_csi_trace, frequency, sub_freq_delta, antenna_distance, plot_switch);
	[output_top_aoas] = normalized_likelihood(tof_packet_data, aoa_packet_data, num_packets);
    fprintf('The Total RSS of The First Package is %f\n',csi_rss);
end
function ret = get_total_RSS_SHL(csi_trace)
    error(nargchk(1,1,nargin));
    flag = cellfun(@isempty,csi_trace);
    k=1;
    total_rss=0;
    for i=1:size(csi_trace)
        if flag(i,1)==0         
            rssi_mag = 0 ;
            if csi_trace{k}.rssi_a ~=0
                rssi_mag=dbinv(csi_trace{k}.rssi_a)+rssi_mag;
            end
            if csi_trace{k}.rssi_b ~=0
                rssi_mag=dbinv(csi_trace{k}.rssi_b)+rssi_mag;
            end
            if csi_trace{k}.rssi_c ~=0
                rssi_mag=dbinv(csi_trace{k}.rssi_c)+rssi_mag;
            end
            rssi_mag = db(rssi_mag,'pow')-44-csi_trace{k}.agc;
            k=k+1;
        end
        total_rss=total_rss+rssi_mag;
    end
    ret = total_rss/size(csi_trace,1);
end 
function csi_trace = readfile(filepath)
	temp = read_bf_file(filepath);
    flag=cellfun(@isempty,temp);
    k=1;
    for i=1:size(temp,1)
        if flag(i,1)==0
            csi_trace(k,1)=temp(i,1);
            k=k+1;
        end
    end
end
function ret = read_bf_file(filename)
narginchk(1,1);
f = fopen(filename, 'rb');
if (f < 0)
    error('Couldn''t open file %s', filename);
    return;
end
status = fseek(f, 0, 'eof');
if status ~= 0
    [msg, errno] = ferror(f);
    error('Error %d seeking: %s', errno, msg);
    fclose(f);
    return;
end
len = ftell(f);
status = fseek(f, 0, 'bof');
if status ~= 0
    [msg, errno] = ferror(f);
    error('Error %d seeking: %s', errno, msg);
    fclose(f);
    return;
end
ret = cell(ceil(len/95),1);    
cur = 0;                        
count = 0;                      
broken_perm = 0;                
triangle = [1 3 6];             
while cur < (len - 3)
    field_len = fread(f, 1, 'uint16', 0, 'ieee-be');
    code = fread(f,1);
    cur = cur+3;
    if (code == 187) % get beamforming or phy data
        bytes = fread(f, field_len-1, 'uint8=>uint8');
        cur = cur + field_len - 1;
        if (length(bytes) ~= field_len-1)
            fclose(f);
            return;
        end
    else 
        fseek(f, field_len - 1, 'cof');
        cur = cur + field_len - 1;
        continue;
    end
    if (code == 187)
        count = count + 1;
        ret{count} = read_bfee(bytes);
        perm = ret{count}.perm;
        Nrx = ret{count}.Nrx;
        if Nrx == 1 
            continue;
        end
        if sum(perm) ~= triangle(Nrx)
            if broken_perm == 0
                broken_perm = 1;
                fprintf('WARN ONCE: Found CSI (%s) with Nrx=%d and invalid perm=[%s]\n', filename, Nrx, int2str(perm));
            end
        else
            ret{count}.csi(:,perm(1:Nrx),:) = ret{count}.csi(:,1:Nrx,:);
        end
    end
end
ret = ret(1:count);
fclose(f);
end
function sampled_csi = csi_sampling(csi_trace, n, alt_begin_index, alt_end_index)
    if nargin < 3
        begin_index = 1;
        end_index = length(csi_trace);
    elseif nargin < 4
        begin_index = alt_begin_index;
        end_index = length(csi_trace);
    elseif nargin == 4
        begin_index = alt_begin_index;
        end_index = alt_end_index;
    end
    sampling_interval = floor((end_index - begin_index + 1) / n);
    sampled_csi = cell(n, 1);
    jj = 1;
    for ii = begin_index:sampling_interval:end_index
        sampled_csi{jj} = csi_trace{ii};
        jj = jj + 1;
    end
end
function [aoa_packet_data, tof_packet_data] = run_music(csi_trace, frequency, sub_freq_delta, antenna_distance, plot_switch)
    num_packets = length(csi_trace);
    aoa_packet_data = cell(num_packets, 1);
    tof_packet_data = cell(num_packets, 1);
    parfor (packet_index = 1:num_packets, 4)
        csi_entry = csi_trace{packet_index};
        csi = get_scaled_csi(csi_entry);
        csi = csi(1, :, :);
        csi = squeeze(csi);
        csi_row2 = csi(2,:);
        csi_row3 = csi(3,:);
        csi(2,:) = csi_row3;
        csi(3,:) = csi_row2;
        smoothed_sanitized_csi = smooth_csi(csi);
        [aoa_packet_data{packet_index}, tof_packet_data{packet_index}] = aoa_tof_music(...
                smoothed_sanitized_csi, antenna_distance, frequency, sub_freq_delta, plot_switch);
    end
end
function ret = get_scaled_csi(csi_st)
    csi = csi_st.csi;
    csi_sq = csi .* conj(csi);
    csi_pwr = sum(csi_sq(:));
    rssi_pwr = dbinv(get_total_rss(csi_st));
    scale = rssi_pwr / (csi_pwr / 30);
    if (csi_st.noise == -127)
        noise_db = -92;
    else
        noise_db = csi_st.noise;
    end
    thermal_noise_pwr = dbinv(noise_db);
    quant_error_pwr = scale * (csi_st.Nrx * csi_st.Ntx);
    total_noise_pwr = thermal_noise_pwr + quant_error_pwr;
    ret = csi * sqrt(scale / total_noise_pwr);
    if csi_st.Ntx == 2
        ret = ret * sqrt(2);
    elseif csi_st.Ntx == 3
        ret = ret * sqrt(dbinv(4.5));
    end
end
function ret = dbinv(x)
    ret = 10.^(x/10);
end
function [estimated_aoas, estimated_tofs] = aoa_tof_music(x,antenna_distance, frequency, sub_freq_delta, plot_switch)
    R = x * x'; 
    [eigenvectors, eigenvalue_matrix] = eig(R);
    eigenvalues = diag(eigenvalue_matrix);
    [eigenvalues, eigenvectors] = sort_eigenvectors(eigenvalues, eigenvectors);
    eigenvalues_descend = sort(eigenvalues, 'descend');
    num_computed_paths = aic_new(30, 32, eigenvalues_descend);
    column_indices = 1:(size(eigenvalue_matrix, 1) - num_computed_paths);
    eigenvectors_noise = eigenvectors(:, column_indices); 
    column_sig_indices = (size(eigenvalue_matrix, 1) - num_computed_paths+1):size(eigenvalue_matrix, 1);
    eigenvectors_sig = eigenvectors(:,column_sig_indices);
    theta = -90:1:90; 
    tau = 0:(2.0 * 10^-9):(400 * 10^-9);
    Pmusic = zeros(length(theta), length(tau));
    for ii = 1:length(theta)
        for jj = 1:length(tau)
            steering_vector = compute_steering_vector(theta(ii), tau(jj), ...
                    frequency, sub_freq_delta, antenna_distance);
            PP = steering_vector' * (eigenvectors_noise * eigenvectors_noise') * steering_vector;
            Pmusic(ii, jj) = abs(1 /  PP);
            Pmusic(ii, jj) = 10 * log10(Pmusic(ii, jj)); 
        end
    end
    [pks,locs,xymin,smin] = extrema2(Pmusic,0.5);
    estimated_aoas = theta(locs(:,1));
    estimated_tofs = tau(locs(:,2));
end
function steering_vector = compute_steering_vector(theta, tau, freq, sub_freq_delta, ant_dist)
    steering_vector = zeros(30, 1);
    k = 1;
    base_element = 1;
    for ii = 1:2
        for jj = 1:15
            steering_vector(k, 1) = base_element * omega_tof_phase(tau, sub_freq_delta)^(jj - 1);
            k = k + 1;
        end
        base_element = base_element * phi_aoa_phase(theta, freq, ant_dist);
    end
end
function time_phase = omega_tof_phase(tau, sub_freq_delta)
    time_phase = exp(-1i * 2 * pi * sub_freq_delta * tau);
end
function angle_phase = phi_aoa_phase(theta, frequency, d)
    c = 3.0 * 10^8;
    theta = theta / 180 * pi;
    angle_phase = exp(-1i * 2 * pi * d * sin(theta) * (frequency / c));
end
function [sorted_eigenvalues,sorted_eigenvectors] = sort_eigenvectors(eigenvalues, eigenvectors)
    [sorted_eigenvalues, b] = sort(eigenvalues);
    sorted_eigenvectors = eigenvectors(:,b);
end
function ret = get_total_rss(csi_st)
    error(nargchk(1,1,nargin));
    rssi_mag = 0;
    if csi_st.rssi_a ~= 0
        rssi_mag = rssi_mag + dbinv(csi_st.rssi_a);
    end
    if csi_st.rssi_b ~= 0
        rssi_mag = rssi_mag + dbinv(csi_st.rssi_b);
    end
    if csi_st.rssi_c ~= 0
        rssi_mag = rssi_mag + dbinv(csi_st.rssi_c);
    end
    
    ret = db(rssi_mag, 'pow') - 44 - csi_st.agc;
end
function n = aic_new(M, L, eigenvalues)
    aic_values = zeros(29,1);
    for ii = 1:29
        delta_n = compute_delta_n(M, ii, eigenvalues);
        aic_values(ii) = -(M-ii)*L*log(delta_n)+(1/2)*ii*(2*M-ii)*log(L);
    end
    [~, n] = min(aic_values); 
end
function delta_n = compute_delta_n(M, n, eigenvalues)
    sum_lam = 0;
    for ii = n+1:1:M
        sum_lam = sum_lam + eigenvalues(ii);
    end
    pro_lam = 1;
    for ii = n+1:1:M
        pro_lam = pro_lam * eigenvalues(ii);
    end
    delta_n = (pro_lam^(1/(M-n)))/((1/(M-n))*sum_lam);
end
function smoothed_csi = smooth_csi(csi)
    smoothed_csi = zeros(size(csi, 2), size(csi, 2));
    m = 1;
    for ii = 1:1:15
        n = 1;
        for j = ii:1:(ii + 15)
            smoothed_csi(m, n) = csi(1, j); % 1 + sqrt(-1) * j;
            n = n + 1;
        end
        m = m + 1;
    end
    for ii = 1:1:15
        n = 1;
        for j = ii:1:(ii + 15)
            smoothed_csi(m, n) = csi(2, j); % 2 + sqrt(-1) * j;
            n = n + 1;
        end
        m = m + 1;
    end
    m = 1;
    for ii = 1:1:15
        n = 17;
        for j = ii:1:(ii + 15)
            smoothed_csi(m, n) = csi(2, j); %2 + sqrt(-1) * j;
            n = n + 1;
        end
        m = m + 1;
    end 
    for ii = 1:1:15
        n = 17;
        for j = ii:1:(ii + 15)
            smoothed_csi(m, n) = csi(3, j); %3 + sqrt(-1) * j;
            n = n + 1;
        end
        m = m + 1;
    end
end
function [output_top_aoas] = normalized_likelihood(tof_packet_data, aoa_packet_data, num_packets,data_name)
    if nargin < 4
        data_name = ' - ';
    end
    full_measurement_matrix_size = 0;
    for packet_index = 1:num_packets
        tof_matrix = tof_packet_data{packet_index};
        aoa_matrix = aoa_packet_data{packet_index};
        for j = 1:size(aoa_matrix, 1)
            for k = 1:size(tof_matrix(j, :), 2)
                if tof_matrix(j, k) < 0
                    break
                end
                full_measurement_matrix_size = full_measurement_matrix_size + 1;
            end
        end
    end
    full_measurement_matrix = zeros(full_measurement_matrix_size, 2);%????????????????????????????????
    full_measurement_matrix_index = 1;
    for packet_index = 1:num_packets
        tof_matrix = tof_packet_data{packet_index};
        aoa_matrix = aoa_packet_data{packet_index};
        for j = 1:size(aoa_matrix, 1)
            for k = 1:size(tof_matrix(j, :), 2)
                if tof_matrix(j, k) < 0
                    break
                end
                full_measurement_matrix(full_measurement_matrix_index, 1) = aoa_matrix(j, 1);
                full_measurement_matrix(full_measurement_matrix_index, 2) = tof_matrix(j, k);
                full_measurement_matrix_index = full_measurement_matrix_index + 1;
            end
        end
    end
     Y = pdist(full_measurement_matrix, 'seuclidean');
     linkage_tree = linkage(Y, 'average');
     cluster_indices_vector = cluster(linkage_tree,'CutOff', 2.0);
    cluster_count_vector = zeros(0, 1);
    num_clusters = 0;
    for ii = 1:size(cluster_indices_vector, 1)
        if ~ismember(cluster_indices_vector(ii), cluster_count_vector)
            cluster_count_vector(size(cluster_count_vector, 1) + 1, 1) = cluster_indices_vector(ii);
            num_clusters = num_clusters + 1;
        end
    end
    clusters = cell(num_clusters, 1);
    cluster_indices = cell(num_clusters, 1);
    for ii = 1:size(cluster_indices_vector, 1)
        tail_index = size(clusters{cluster_indices_vector(ii, 1)}, 1) + 1;
        clusters{cluster_indices_vector(ii, 1)}(tail_index, :) = full_measurement_matrix(ii, :);
        cluster_index_tail_index = size(cluster_indices{cluster_indices_vector(ii, 1)}, 1) + 1;
        cluster_indices{cluster_indices_vector(ii, 1)}(cluster_index_tail_index, 1) = ii;
    end
    for ii = 1:size(clusters, 1)
        if size(clusters{ii}, 1) < (0.05 * num_packets)
            clusters{ii} = [];
            cluster_indices{ii} = [];
            continue;
        end
        alpha = 0.05;
        [~, outlier_indices, ~] = deleteoutliers(clusters{ii}(:, 1), alpha);
        cluster_indices{ii}(outlier_indices(:), :) = [];
        clusters{ii}(outlier_indices(:), :) = [];

        alpha = 0.05;
        [~, outlier_indices, ~] = deleteoutliers(clusters{ii}(:, 2), alpha);
        cluster_indices{ii}(outlier_indices(:), :) = [];
        clusters{ii}(outlier_indices(:), :) = [];
    end

    cluster_plot_style = {'bo', 'go', 'ro', 'ko', ...
                        'bs', 'gs', 'rs', 'ks', ...
                        'b^', 'g^', 'r^', 'k^', ... 
                        'bp', 'gp', 'rp', 'kp', ... 
                        'b*', 'g*', 'r*', 'k*', ... 
                        'bh', 'gh', 'rh', 'kh', ... 
                        'bx', 'gx', 'rx', 'kx', ... 
                        'b<', 'g<', 'r<', 'k<', ... 
                        'b>', 'g>', 'r>', 'k>', ... 
                        'b+', 'g+', 'r+', 'k+', ... 
                        'bd', 'gd', 'rd', 'kd', ... 
                        'bv', 'gv', 'rv', 'kv', ... 
                        'b.', 'g.', 'r.', 'k.', ... 
                        'co', 'mo', 'yo', 'wo', ...
                        'cs', 'ms', 'ys', ...
                        'c^', 'm^', 'y^', ... 
                        'cp', 'mp', 'yp', ... 
                        'c*', 'm*', 'y*', ... 
                        'ch', 'mh', 'yh', ... 
                        'cx', 'mx', 'yx', ... 
                        'c<', 'm<', 'y<', ... 
                        'c>', 'm>', 'y>', ... 
                        'c+', 'm+', 'y+', ... 
                        'cd', 'md', 'yd', ... 
                        'cv', 'mv', 'yv', ... 
                        'c.', 'm.', 'y.', ... 
    };
    weight_num_cluster_points = 0.0;
    weight_aoa_variance = 0.0004;
    weight_tof_variance = -0.0016;
    weight_tof_mean = -0.0000;
    constant_offset = -1;
    likelihood = zeros(length(clusters), 1);
    cluster_aoa = zeros(length(clusters), 1);
    max_likelihood_index = -1;
    top_likelihood_indices = [-1; -1; -1; -1; -1;];
    for ii = 1:length(clusters)
        if size(clusters{ii}, 1) == 0
            continue
        end
        num_cluster_points = size(clusters{ii}, 1);
        aoa_mean = 0;
        tof_mean = 0;
        aoa_variance = 0;
        tof_variance = 0;
        for jj = 1:num_cluster_points
            aoa_mean = aoa_mean + clusters{ii}(jj, 1);
            tof_mean = tof_mean + clusters{ii}(jj, 2);
        end
        aoa_mean = aoa_mean / num_cluster_points;
        tof_mean = tof_mean / num_cluster_points;
        for jj = 1:num_cluster_points
            aoa_variance = aoa_variance + (clusters{ii}(jj, 1) - aoa_mean)^2;
            tof_variance = tof_variance + (clusters{ii}(jj, 2) - tof_mean)^2;
        end
        aoa_variance = aoa_variance / (num_cluster_points - 1);
        tof_variance = tof_variance / (num_cluster_points - 1);
        exp_body = weight_num_cluster_points * num_cluster_points ...
                + weight_aoa_variance * aoa_variance ...
                + weight_tof_variance * tof_variance ...
                + weight_tof_mean * tof_mean ...
                + constant_offset;
        likelihood(ii, 1) = exp_body;
        for jj = 1:size(clusters{ii}, 1)
            cluster_aoa(ii, 1) = cluster_aoa(ii, 1) + clusters{ii}(jj, 1);
        end
        cluster_aoa(ii, 1) = cluster_aoa(ii, 1) / size(clusters{ii}, 1);
        if max_likelihood_index == -1 ...
                || likelihood(ii, 1) > likelihood(max_likelihood_index, 1)
            max_likelihood_index = ii;
        end
        for jj = 1:size(top_likelihood_indices, 1)
            if top_likelihood_indices(jj, 1) == -1
                top_likelihood_indices(jj, 1) = ii;
                break;
            elseif likelihood(ii, 1) > likelihood(top_likelihood_indices(jj, 1), 1)
                for kk = size(top_likelihood_indices, 1):-1:(jj + 1)
                    top_likelihood_indices(kk, 1) = top_likelihood_indices(kk - 1, 1);
                end
                top_likelihood_indices(jj, 1) = ii;
                break;
            elseif likelihood(ii, 1) == likelihood(top_likelihood_indices(jj, 1), 1) ...
                    && jj == size(top_likelihood_indices, 1)
                top_likelihood_indices(jj + 1, 1) = ii;
                break;
            elseif jj == size(top_likelihood_indices, 1) 
                top_likelihood_indices(jj + 1, 1) = ii;
                break;
            end
        end
    end
	fprintf('\n')
    max_likelihood_average_aoa = cluster_aoa(max_likelihood_index, 1);
    fprintf('The Estimated Angle of Arrival for data set is %f\n',max_likelihood_average_aoa);
     fid = fopen('result.txt','wt');
     fprintf(fid,'%f',max_likelihood_average_aoa);
     fclose(fid);
%     dlmwrite('result.txt',max_likelihood_average_aoa,'precision','%f');
    ii = size(top_likelihood_indices, 1);
    while ii > 0
        if top_likelihood_indices(ii, 1) == -1
            top_likelihood_indices(ii, :) = [];
            ii = ii - 1;
        else
            break;
        end
    end
    output_top_aoas = cluster_aoa(top_likelihood_indices);
end
function [xmax,imax,xmin,imin] = extrema(x)

xmax = [];
imax = [];
xmin = [];
imin = [];

% Vector input?
Nt = numel(x);
if Nt ~= length(x)
 error('Entry must be a vector.')
end

% NaN's:
inan = find(isnan(x));
indx = 1:Nt;
if ~isempty(inan)
 indx(inan) = [];
 x(inan) = [];
 Nt = length(x);
end

% Difference between subsequent elements:
dx = diff(x);

% Is an horizontal line?
if ~any(dx)
 return
end

% Flat peaks? Put the middle element:
a = find(dx~=0);              % Indexes where x changes
lm = find(diff(a)~=1) + 1;    % Indexes where a do not changes
d = a(lm) - a(lm-1);          % Number of elements in the flat peak
a(lm) = a(lm) - floor(d/2);   % Save middle elements
a(end+1) = Nt;
xa  = x(a);             % Serie without flat peaks
b = (diff(xa) > 0);     % 1  =>  positive slopes (minima begin)  
                        % 0  =>  negative slopes (maxima begin)
xb  = diff(b);          % -1 =>  maxima indexes (but one) 
                        % +1 =>  minima indexes (but one)
imax = find(xb == -1) + 1; % maxima indexes
imin = find(xb == +1) + 1; % minima indexes
imax = a(imax);
imin = a(imin);

nmaxi = length(imax);
nmini = length(imin);                
if (nmaxi==0) && (nmini==0)
 if x(1) > x(Nt)
  xmax = x(1);
  imax = indx(1);
  xmin = x(Nt);
  imin = indx(Nt);
 elseif x(1) < x(Nt)
  xmax = x(Nt);
  imax = indx(Nt);
  xmin = x(1);
  imin = indx(1);
 end
 return
end
if (nmaxi==0) 
 imax(1:2) = [1 Nt];
elseif (nmini==0)
 imin(1:2) = [1 Nt];
else
 if imax(1) < imin(1)
  imin(2:nmini+1) = imin;
  imin(1) = 1;
 else
  imax(2:nmaxi+1) = imax;
  imax(1) = 1;
 end
 if imax(end) > imin(end)
  imin(end+1) = Nt;
 else
  imax(end+1) = Nt;
 end
end
xmax = x(imax);
xmin = x(imin);
if ~isempty(inan)
 imax = indx(imax);
 imin = indx(imin);
end
imax = reshape(imax,size(xmax));
imin = reshape(imin,size(xmin));
[temp,inmax] = sort(-xmax); clear temp
xmax = xmax(inmax);
imax = imax(inmax);
[xmin,inmin] = sort(xmin);
imin = imin(inmin);
end
function [xymax,loc_max,xymin,smin] = extrema2(xy,t)
M = size(xy);
if length(M) ~= 2
 error('Entry must be a matrix.')
end
N = M(2);
M = M(1);
[smaxcol,smincol] = extremos(xy);
im = unique([smaxcol(:,1);smincol(:,1)]); % Rows with column extrema
[smaxfil,sminfil] = extremos(xy(im,:).');
smaxcol = sub2ind([M,N],smaxcol(:,1),smaxcol(:,2));
smincol = sub2ind([M,N],smincol(:,1),smincol(:,2));
smaxfil = sub2ind([M,N],im(smaxfil(:,2)),smaxfil(:,1));
sminfil = sub2ind([M,N],im(sminfil(:,2)),sminfil(:,1));
smax = intersect(smaxcol,smaxfil);
smin = intersect(smincol,sminfil);
 [iext,jext] = ind2sub([M,N],unique([smax;smin]));
 [sextmax,sextmin] = extremos_diag(iext,jext,xy,1);
 smax = intersect(smax,[M; (N*M-M); sextmax]);
 smin = intersect(smin,[M; (N*M-M); sextmin]);
 [iext,jext] = ind2sub([M,N],unique([smax;smin]));
 [sextmax,sextmin] = extremos_diag(iext,jext,xy,-1);
 smax = intersect(smax,[1; N*M; sextmax]);
 smin = intersect(smin,[1; N*M; sextmin]);
xymax = xy(smax);
xymin = xy(smin);
[temp,inmax] = sort(-xymax); clear temp
xymax = xymax(inmax);
smax = smax(inmax);
index = find(xymax > t);
xymax = xymax(index);
smax = smax(index);
[xymin,inmin] = sort(xymin);
smin = smin(inmin);
[row_max,col_max] = ind2sub(size(xy),smax);
loc_max = [row_max col_max];
end
function [smax,smin] = extremos(matriz)
% Peaks through columns or rows.

smax = [];
smin = [];

for n = 1:length(matriz(1,:))
 [temp,imaxfil,temp,iminfil] = extrema(matriz(:,n)); clear temp
 if ~isempty(imaxfil)     % Maxima indexes
  imaxcol = repmat(n,length(imaxfil),1);
  smax = [smax; imaxfil imaxcol];
 end
 if ~isempty(iminfil)     % Minima indexes
  imincol = repmat(n,length(iminfil),1);
  smin = [smin; iminfil imincol];
 end
end
end
function [sextmax,sextmin] = extremos_diag(iext,jext,xy,A)

[M,N] = size(xy);
if A==-1
 iext = M-iext+1;
end
[iini,jini] = cruce(iext,jext,1,1);
[iini,jini] = ind2sub([M,N],unique(sub2ind([M,N],iini,jini)));
[ifin,jfin] = cruce(iini,jini,M,N);
sextmax = [];
sextmin = [];
for n = 1:length(iini)
 ises = iini(n):ifin(n);
 jses = jini(n):jfin(n);
 if A==-1
  ises = M-ises+1;
 end
 s = sub2ind([M,N],ises,jses);
 [temp,imax,temp,imin] = extrema(xy(s)); clear temp
 sextmax = [sextmax; s(imax)'];
 sextmin = [sextmin; s(imin)'];
end
end
function [i,j] = cruce(i0,j0,I,J)

arriba = 2*(I*J==1)-1;

si = (arriba*(j0-J) > arriba*(i0-I));
i = (I - (J+i0-j0)).*si + J+i0-j0;
j = (I+j0-i0-(J)).*si + J;

end
function [b,idx,outliers] = deleteoutliers(a,alpha,rep)
if nargin == 1
	alpha = 0.05;
	rep = 0;
elseif nargin == 2
	rep = 0;
elseif nargin == 3
	if ~ismember(rep,[0 1])
		error('Please enter a 1 or a 0 for optional argument rep.')
	end
elseif nargin > 3
	error('Requires 1,2, or 3 input arguments.');
end

if isempty(alpha)
	alpha = 0.05;
end

b = a;
b(isinf(a)) = NaN;
%Delete outliers:
outlier = 1;
while outlier
	tmp = b(~isnan(b));
	meanval = mean(tmp);
	maxval = tmp(find(abs(tmp-mean(tmp))==max(abs(tmp-mean(tmp)))));
	maxval = maxval(1);
	sdval = std(tmp);
	tn = abs((maxval-meanval)/sdval);
	critval = zcritical(alpha,length(tmp));
	outlier = tn > critval;
	if outlier
		tmp = find(a == maxval);
		b(tmp) = NaN;
    end
end
if nargout >= 2
	idx = find(isnan(b));
end
if nargout > 2
	outliers = a(idx);
end
if ~rep
    b=b(~any(isnan(b), 2), :);
end
return
end
function zcrit = zcritical(alpha,n)
tcrit = tinv(alpha/(2*n),n-2);
zcrit = (n-1)/sqrt(n)*(sqrt(tcrit^2/(n-2+tcrit^2)));
end
