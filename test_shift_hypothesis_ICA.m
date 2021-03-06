clear all; close all; clc

% Set inputs:
d = 200; 
group_amplitude = 1; % Set to 1 to switch off using subject-based amplitude stuff
group_maps = 0; % Set to 1 to switch off using subject PFM maps in simulation
map_thresh = 1; % Set to 1 for a fixed threshold and to -95 for a percentile threshold
map_bin = 1; % Set to 1 to threshold and binarize subject maps
subject_nets = 0; % Set to 1 to use subject netmats rather than group netmats

% Set paths:
path(path,fullfile('/vols/Scratch/janineb','matlab','cifti-matlab'))
path(path,'/home/fs0/janineb/scratch/HCP/DMN/DMN_functions/')
addpath ~steve/NETWORKS/FSLNets;
path(path,'/home/fs0/janineb/scratch/matlab')

% Load PFM group maps
PFMmaps = ft_read_cifti('/vols/Scratch/janineb/PROFUMO/PFMnew_S820_M50_Aug16_FinalModel.dtseries.nii');
PFMmaps = PFMmaps.dtseries; PFMmaps(isnan(PFMmaps(:,1))==1,:) = [];
pPFMmaps = pinv(nets_demean(PFMmaps)); 
if group_amplitude == 1
    load('group_amplitude_inputs.mat')
end

% Load ICA group maps
ICAmaps = ft_read_cifti(sprintf('/vols/Data/HCP/Phase2/group900/groupICA/groupICA_3T_HCP820_MSMAll_d%d.ica/melodic_IC.dtseries.nii',d));
ICAmaps = ICAmaps.dtseries; ICAmaps(isnan(ICAmaps(:,1))==1,:) = [];
pICAmaps = pinv(nets_demean(ICAmaps)); 

% Load ICA subject timeseries
in = 'MSMAll'; Ddir = sprintf('3T_HCP820_%s_d%d_ts2',in,d);
HCPdir = '/vols/Data/HCP/Phase2/group900';
tsICA = nets_load(fullfile(HCPdir,'node_timeseries',Ddir),0.72,1,1);

% Load ground truth netmats created using test_shift_hypothesis_create_ground_truth.m
load Ground_truth_netmat_PFMnew.mat

% Load PFM subject maps
PFMdir = '/home/fs0/samh/scratch/HCP/S820_M50_Aug16.pfm/FinalModel/';
Subject_maps = PFM_loadSubjectSpatialMaps(PFMdir,1:50);

% Load PFM subject timeseries
ts = PFM_loadTimeCourses_pfmNEW(PFMdir,0.72,1,1,0,[]);

% Create simulated data and perform weighted regression of ICA maps onto this
drTC = zeros(size(tsICA.ts,1),size(tsICA.ts,2));
drTC_ORIG = zeros(size(tsICA.ts,1),size(tsICA.ts,2));
subs = dir('/vols/Scratch/janineb/PROFUMO/PFM50_MSMall900/Model7_S.pfm/Subjects/*');
subs = subs(3:end);
runs = {'1_LR','1_RL','2_LR','2_RL'};
if map_thresh < 0; Uthr = zeros(ts.Nsubjects,ts.Nnodes); Lthr = zeros(ts.Nsubjects,ts.Nnodes); end

for s = 1:ts.Nsubjects
    fprintf('running subject %d \n', s)

    % Get subject timeseries
    TCall = ts.ts((s-1)*ts.NtimepointsPerSubject+1:s*ts.NtimepointsPerSubject,:);
    dr_tmp = []; dr_tmp2 = [];
    
    for x = 1:4;
        % Get run timeseries
        TC = TCall((x-1)*1200+1:x*1200,:);
        
        % Get subject correlations
        sCov = cov(TC);
        sStd = sqrt(diag(sCov));
        sCorr = diag(1./sStd) * sCov * diag(1./sStd);
        
        % And make a new set of time series without any temporal information
        newTC = TC * diag( 1 ./ sStd );         % Variance normalise
        newTC = newTC * sCorr ^-0.5;            % Remove correlations
        if subject_nets == 1
            newTC = newTC * sCorr^0.5;
        else
            newTC = newTC * GTnet^0.5;          % Add in ground truth correlations
        end
        newTC = newTC * diag( 1./std(newTC) );  % Variance normalise again
        if group_amplitude == 1
            sStd = sStd_group;
        end
        newTC = newTC * diag( sStd );           % Add back in the original variances
        
        % Load posterior nosie variance and amplitude weights needed for creating full dataset
        if group_amplitude == 0
            a = importfile(fullfile(PFMdir,'Subjects', subs(s).name,'Runs',runs{x},'NoisePrecision.post','GammaPosterior.txt'));
            noiseStd = sqrt(a(2)/a(1));
            H = h5read(fullfile(PFMdir,'Subjects',subs(s).name,'Runs',runs{x},'ComponentWeightings.post','Means.hdf5'),'/dataset');
        elseif group_amplitude == 1
            noiseStd = noiseStd_group;
            H = H_group;
        end
        
        % Select correct maps and apply threshold if desired
        if group_maps == 0
            M = squeeze(Subject_maps(s,:,:));
        elseif group_maps == 1
            M = PFMmaps;
        end
        if map_thresh > 0
            Mnew = zeros(size(M));
            Mnew(M<-map_thresh) = M(M<-map_thresh);
            Mnew(M>map_thresh) = M(M>map_thresh);
            M = Mnew;
        end
        if map_thresh < 0
            Mnew = zeros(size(M));
            for p = 1:50
                Uthr(s,p) = prctile(M(:,p),-map_thresh);
                Lthr(s,p) = prctile(M(:,p),100+map_thresh);
                Mnew(M(:,p)<Lthr(s,p),p) = M(M(:,p)<Lthr(s,p),p);
                Mnew(M(:,p)>Uthr(s,p),p) = M(M(:,p)>Uthr(s,p),p);
            end
            M = Mnew;
        end
        if map_bin ~= 0
            Mnew = zeros(size(M));
            Mnew(M<0) = -1;
            Mnew(M>0) = 1;
            M = Mnew;
        end
        
        % Take outer product and add noise to create full dataset
        D = M * diag(H) * newTC' + noiseStd * randn(91282, 1200);
        
        % Undo variance normalisation that PFM pipeline applies (to avoid issues with relative strength of subcortical modes)
        if group_amplitude == 0
            norm = h5read(fullfile(PFMdir,'..','Preprocessing',subs(s).name,sprintf('%s_Normalisation.hdf5',runs{x})),'/dataset')';
        elseif group_amplitude == 1
            norm = norm_group';
        end
        D = bsxfun(@times, D, 1./norm');
        
        % Run dual regression against group ICA:
        dr_tmp = [dr_tmp; nets_demean((pPFMmaps*nets_demean(D))')];
        
        % Get timeseries from original data
        D = ft_read_cifti(sprintf('/vols/Data/HCP/Phase2/subjects900/%s/MNINonLinear/Results/rfMRI_REST%s/rfMRI_REST%s_Atlas_MSMAll_hp2000_clean.dtseries.nii',subs(s).name,runs{x},runs{x}));
        D = D.dtseries; D(isnan(D(:,1))==1,:) = [];
        dr_tmp2 = [dr_tmp2; nets_demean((pPFMmaps*nets_demean(D))')];
    end
    drTC((s-1)*ts.NtimepointsPerSubject+1:s*ts.NtimepointsPerSubject,:) = dr_tmp;
    drTC_ORIG((s-1)*ts.NtimepointsPerSubject+1:s*ts.NtimepointsPerSubject,:) = dr_tmp2;
end
clear D i dr_tmp dd s TC newTC Snet Sstd
        
% Initialise output
OUTPUT_all_nodes = zeros(2,5);
OUTPUT_cortex = zeros(2,5);
OUTPUT_subcortex = zeros(2,5);
% Row 1 = full and Row 2 = partial

% Calculate original and new subject netmats
tsNEW = ts;
tsNEW.ts = drTC; clear drTC
F.netNEW = nets_netmats(tsNEW,-1,'corr');
F.netORIG = nets_netmats(tsICA,-1,'corr');
P.netNEW = nets_netmats(tsNEW,-1,'ridgep',0.01);
P.netORIG = nets_netmats(tsICA,-1,'ridgep',0.01);

% Normalise netmats
F.netNEW_norm = F.netNEW ./ repmat(std(F.netNEW,[],2),1,size(F.netNEW,2));
F.netORIG_norm = F.netORIG ./ repmat(std(F.netORIG,[],2),1,size(F.netORIG,2));
P.netNEW_norm = P.netNEW ./ repmat(std(P.netNEW,[],2),1,size(P.netNEW,2));
P.netORIG_norm = P.netORIG ./ repmat(std(P.netORIG,[],2),1,size(P.netORIG,2));

% Calculate group average netmats
[F.ZnetNEW,F.MnetNEW] = nets_groupmean(F.netNEW,0);
[F.ZnetORIG,F.MnetORIG] = nets_groupmean(F.netORIG,0);
[P.ZnetNEW,P.MnetNEW] = nets_groupmean(P.netNEW,0);
[P.ZnetORIG,P.MnetORIG] = nets_groupmean(P.netORIG,0);
[F.ZnetNEW_norm,F.MnetNEW_norm] = nets_groupmean(F.netNEW_norm,0);
[F.ZnetORIG_norm,F.MnetORIG_norm] = nets_groupmean(F.netORIG_norm,0);
[P.ZnetNEW_norm,P.MnetNEW_norm] = nets_groupmean(P.netNEW_norm,0);
[P.ZnetORIG_norm,P.MnetORIG_norm] = nets_groupmean(P.netORIG_norm,0);

% Correlate subject*subject correlation matrices
F.corr_NEW = corr(F.netNEW'); F.corr_ORIG = corr(F.netORIG');
A = F.corr_NEW(:); A(eye(size(F.corr_NEW))==1) = []; B = F.corr_ORIG(:); B(eye(size(F.corr_ORIG))==1) = [];
OUTPUT_all_nodes(1,1) = corr(A,B);
P.corr_NEW = corr(P.netNEW'); P.corr_ORIG = corr(P.netORIG');
A = P.corr_NEW(:); A(eye(size(F.corr_NEW))==1) = []; B = P.corr_ORIG(:); B(eye(size(F.corr_NEW))==1) = [];
OUTPUT_all_nodes(2,1) = corr(A,B);
if d==200
    cortex = zeros(d); cortex(1:67,1:67) = 1; cortex = find(cortex==1);
    subcortex = zeros(d); subcortex(68:end,68:end) = 1; subcortex = find(subcortex==1);
    
    nw = corr(F.netNEW(:,cortex)'); od = corr(F.netORIG(:,cortex)');
    nw = nw(:); nw(nw==1) = []; od = od(:); od(od==1) = [];
    OUTPUT_cortex(1,1) = corr(nw,od);
    nw = corr(P.netNEW(:,cortex)'); od = corr(P.netORIG(:,cortex)');
    nw = nw(:); nw(nw==1) = []; od = od(:); od(od==1) = [];
    OUTPUT_cortex(2,1) = corr(nw,od);
    
    nw = corr(F.netNEW(:,subcortex)'); od = corr(F.netORIG(:,subcortex)');
    nw = nw(:); nw(nw==1) = []; od = od(:); od(od==1) = [];
    OUTPUT_subcortex(1,1) = corr(nw,od);
    nw = corr(P.netNEW(:,subcortex)'); od = corr(P.netORIG(:,subcortex)');
    nw = nw(:); nw(nw==1) = []; od = od(:); od(od==1) = [];
    OUTPUT_subcortex(2,1) = corr(nw,od);
end

% Subtract & regress netmats
GRP = repmat(F.MnetNEW(:)',ts.Nsubjects,1);
F.netNEWsubtr = F.netNEW - GRP;
F.netNEWregr = F.netNEW - demean(GRP) * pinv(demean(GRP))*demean(F.netNEW);
GRP = repmat(F.MnetORIG(:)',ts.Nsubjects,1);
F.netORIGsubtr = F.netORIG - GRP;
F.netORIGregr = F.netORIG - demean(GRP) * pinv(demean(GRP))*demean(F.netORIG);
GRP = repmat(P.MnetNEW(:)',ts.Nsubjects,1);
P.netNEWsubtr = P.netNEW - GRP;
P.netNEWregr = P.netNEW - demean(GRP) * pinv(demean(GRP))*demean(P.netNEW);
GRP = repmat(P.MnetORIG(:)',ts.Nsubjects,1);
P.netORIGsubtr = P.netORIG - GRP;
P.netORIGregr = P.netORIG - demean(GRP) * pinv(demean(GRP))*demean(P.netORIG);
clear GRP
GRP = repmat(F.MnetNEW_norm(:)',ts.Nsubjects,1);
F.netNEWsubtr_norm = F.netNEW_norm - GRP;
F.netNEWregr_norm = F.netNEW_norm - demean(GRP) * pinv(demean(GRP))*demean(F.netNEW_norm);
GRP = repmat(F.MnetORIG_norm(:)',ts.Nsubjects,1);
F.netORIGsubtr_norm = F.netORIG_norm - GRP;
F.netORIGregr_norm = F.netORIG_norm - demean(GRP) * pinv(demean(GRP))*demean(F.netORIG_norm);
GRP = repmat(P.MnetNEW_norm(:)',ts.Nsubjects,1);
P.netNEWsubtr_norm = P.netNEW_norm - GRP;
P.netNEWregr_norm = P.netNEW_norm - demean(GRP) * pinv(demean(GRP))*demean(P.netNEW_norm);
GRP = repmat(P.MnetORIG_norm(:)',ts.Nsubjects,1);
P.netORIGsubtr_norm = P.netORIG_norm - GRP;
P.netORIGregr_norm = P.netORIG_norm - demean(GRP) * pinv(demean(GRP))*demean(P.netORIG_norm);
clear GRP

% Compare difference between individual and group netmats
[OUTPUT_all_nodes(1,2)] = compare_nets(F.netNEWsubtr,F.netORIGsubtr);
[OUTPUT_all_nodes(1,3)] = compare_nets(F.netNEWregr,F.netORIGregr);
[OUTPUT_all_nodes(1,4)] = compare_nets(F.netNEWsubtr_norm,F.netORIGsubtr_norm);
[OUTPUT_all_nodes(1,5)] = compare_nets(F.netNEWregr_norm,F.netORIGregr_norm);
[OUTPUT_all_nodes(2,2)] = compare_nets(P.netNEWsubtr,P.netORIGsubtr);
[OUTPUT_all_nodes(2,3)] = compare_nets(P.netNEWregr,P.netORIGregr);
[OUTPUT_all_nodes(2,4)] = compare_nets(P.netNEWsubtr_norm,P.netORIGsubtr_norm);
[OUTPUT_all_nodes(2,5)] = compare_nets(P.netNEWregr_norm,P.netORIGregr_norm);

% Concatenate output
OUTPUT = [OUTPUT_all_nodes OUTPUT_cortex OUTPUT_subcortex];
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Look at CCA results for original and new netmats
S = '/home/fs0/janineb/scratch/HCP/CCA/';
Nkeep = 100;
load(fullfile(S,'files','Permutation_100000.mat'),'conf'); conf = demean(conf);

FccaNEW = demean(F.netNEW); FccaNEW(169,:) = [];
FccaNEW = demean(FccaNEW-conf*(pinv(conf)*FccaNEW));
[FccaNEW,~,~]=nets_svds(FccaNEW,Nkeep);
FccaORIG = demean(F.netORIG); FccaORIG(169,:) = [];
FccaORIG = demean(FccaORIG-conf*(pinv(conf)*FccaORIG));
[FccaORIG,~,~]=nets_svds(FccaORIG,Nkeep);

PccaNEW = demean(P.netNEW); PccaNEW(169,:) = [];
PccaNEW = demean(PccaNEW-conf*(pinv(conf)*PccaNEW));
[PccaNEW,~,~]=nets_svds(PccaNEW,Nkeep);
PccaORIG = demean(P.netORIG); PccaORIG(169,:) = [];
PccaORIG = demean(PccaORIG-conf*(pinv(conf)*PccaORIG));
[PccaORIG,~,~]=nets_svds(PccaORIG,Nkeep);

A = '';
if group_maps == 1; A = [A '_using_group_maps']; end
if group_amplitude ==1; A = [A '_using_group_amps']; end
if map_thresh ~= 0; A = sprintf('%s_map_thresh_%d',A,map_thresh); end
if map_bin ~= 0; A = sprintf('%s_bin',A); end
if subject_nets == 1; A = sprintf('%s_using_subject_netmats',A); end
if map_thresh < 0
    save(sprintf('Results/results_%03d%s.mat',d,A),'OUTPUT','F','P','-v7.3','Lthr', 'Uthr')
else
    save(sprintf('Results/results_%03d%s.mat',d,A),'OUTPUT','F','P','-v7.3')
end    
save(sprintf('Results/input_CCA_%03d%s.mat',d,A),'FccaNEW','FccaORIG','PccaNEW','PccaORIG')

    



