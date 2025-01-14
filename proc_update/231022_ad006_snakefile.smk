import pandas as pd
import os
import sys
import swan_vis as swan
import itertools
import cerberus

from utils import *
from sm_utils import *

include: 'download.smk'
include: 'samtools.smk'
include: 'refs.smk'
include: 'talon.smk'
include: 'lapa.smk'
include: 'mapping.smk'
include: 'tc.smk'
include: 'cerberus.smk'
include: 'deeptools.smk'

# settings we can change each time it's run
configfile: 'config.yml'
config_tsv = '231020_config.tsv'
# config_tsv = '231018_config.tsv'
# config_tsv = 'test_local_config.tsv'
meta_tsv = 'mouse_metadata.tsv'
auto_dedupe = True

df = parse_config_file(config_tsv,
                       meta_tsv,
                       auto_dedupe=auto_dedupe,
                       include_humanized=True)
end_modes = ['tss', 'tes']
strands = ['fwd', 'rev']

##############
# only ad006
##############
df = df.loc[df.study == 'ad006']


wildcard_constraints:
    genotype='|'.join([re.escape(x) for x in df.genotype.unique().tolist()]),
    sex='|'.join([re.escape(x) for x in df.sex.unique().tolist()]),
    age='|'.join([re.escape(x) for x in df.age.unique().tolist()]),
    tissue='|'.join([re.escape(x) for x in df.tissue.unique().tolist()]),
    biorep_num='|'.join([re.escape(x) for x in df.biorep_num.unique().tolist()]),
    flowcell='|'.join([re.escape(x) for x in df.flowcell.unique().tolist()]),

ruleorder:
    # cerberus_agg_ics_first > cerberus_agg_ics_seq
    cerb_agg_ics_seq > cerb_agg_ics_first > cerb_agg_ends_seq > cerb_agg_ends_first


rule all:
    input:
        expand(expand(config['merge']['bw'],
               study=df.study.tolist(),
               genotype=df.genotype.tolist(),
               sex=df.sex.tolist(),
               age=df.age.tolist(),
               tissue=df.tissue.tolist(),
               biorep_num=df.biorep_num.tolist(),
               allow_missing=True),
               strand=strands)

################################################################################
#################################### Mapping ###################################
################################################################################
use rule map as map_reads with:
    input:
        fastq = lambda wc: get_df_col(wc, df, 'fname'),
        ref_fa = config['ref']['fa'],
        sjs = config['ref']['sjs']
    output:
        sam = temporary(config['map']['sam']),
        log = config['map']['log']

use rule alignment_stats as map_stats with:
    input:
        alignment = config['map']['sam']
    output:
        stats = config['map']['stats']

use rule rev_alignment as map_rev with:
    input:
        sam = config['map']['sam']
    output:
        sam_rev = temporary(config['map']['sam_rev'])

################################################################################
###################### TranscriptClean ##########################################
################################################################################
use rule tc as tc_sam with:
    input:
        sam = config['map']['sam_rev'],
        fa = config['ref']['fa']
    params:
        path = config['tc']['path'],
        min_intron_size = config['tc']['min_intron_size'],
        opref = config['tc']['sam'].rsplit('_clean.sam', maxsplit=1)[0]
    output:
        sam = temporary(config['tc']['sam']),
        fa = temporary(config['tc']['fa']),
        sam_clean_log = temporary(config['tc']['log']),
        sam_clean_te_log = temporary(config['tc']['te_log'])

use rule alignment_stats as tc_stats with:
    input:
        alignment = config['tc']['sam']
    output:
        stats = config['tc']['stats']

################################################################################
############################## TALON label #####################################
################################################################################
use rule talon_label as talon_label_reads with:
    input:
        fa = config['ref']['fa'],
        sam = config['tc']['sam']
    params:
        frac_a_range = config['talon_label']['frac_a_range'],
        opref = config['talon_label']['sam'].rsplit('_labeled.sam', maxsplit=1)[0]
    output:
        sam = temporary(config['talon_label']['sam'])

use rule sam_to_bam as bam_from_sam with:
    input:
        sam = config['talon_label']['sam']
    output:
        bam = temporary(config['talon_label']['bam'])

use rule sort_bam as bam_sort with:
    input:
        bam = config['talon_label']['bam']
    output:
        bam = temporary(config['talon_label']['sort_bam'])

use rule index_bam as bam_ind with:
    input:
        bam = config['talon_label']['sort_bam']
    output:
        ind = temporary(config['talon_label']['ind_bam'])

################################################################################
################# Merge data from separate flowcells ###########################
##################### Sort, index, make bigwigs ################################
################################################################################
use rule merge_alignment as talon_label_merge with:
    input:
        files = lambda wc:get_cfg_entries(wc, df, config['talon_label']['sort_bam'])
    output:
        bam = temporary(config['merge']['bam'])

use rule sort_bam as bam_sort_merge with:
    input:
        bam = config['merge']['bam']
    output:
        bam = config['merge']['sort_bam']

use rule index_bam as bam_ind_merge with:
    input:
        bam = config['merge']['sort_bam']
    output:
        ind = config['merge']['ind_bam']

use rule bam_to_bw as bw with:
    input:
        bam = config['merge']['sort_bam'],
        bai = config['merge']['ind_bam']
    output:
        bw = config['merge']['bw']

################################################################################
################################## TALON #######################################
################################################################################
rule talon_config:
    input:
        bams = lambda wc:get_cfg_entries(wc, df, config['merge']['sort_bam']),
        bam_inds = lambda wc:get_cfg_entries(wc, df, config['merge']['ind_bam']),
    resources:
        threads = 1,
        mem_gb = 4
    output:
        cfg = config['talon']['config']
    run:
        temp = get_cfg_entries(wildcards, df, config['merge']['bam'], return_df=True)
        temp = temp[['sample', 'dataset', 'platform', 'file']]
        temp.to_csv(output.cfg, index=False, header=None, sep=',')

use rule talon_init as talon_init_db with:
    input:
        gtf = config['ref']['gtf']
    output:
        db = config['ref']['talon']['db']
    params:
        opref = config['ref']['talon']['db'].rsplit('.db', maxsplit=1)[0],
        genome_ver = config['ref']['fa_ver'],
        annot_ver = config['ref']['gtf_ver'],
        min_transcript_len = config['talon']['min_transcript_len'],
        max_5_dist = config['talon']['max_5_dist'],
        max_3_dist = config['talon']['max_3_dist']

use rule talon as talon_run with:
    input:
        db = config['ref']['talon']['db'],
        cfg = config['talon']['config']
    params:
        genome_ver = config['ref']['fa_ver'],
        opref = config['talon']['db'].rsplit('_talon.db', maxsplit=1)[0]
    output:
        db = config['talon']['db'],
        read_annot = config['talon']['annot']

use rule talon_abundance as talon_abundance_run with:
    input:
        db = config['talon']['db']
    params:
        genome_ver = config['ref']['fa_ver'],
        annot_ver = config['ref']['gtf_ver'],
        opref = config['talon']['ab'].rsplit('_talon', maxsplit=1)[0]
    output:
        ab = config['talon']['ab']

use rule talon_filter as talon_filt_run with:
    input:
        db = config['talon']['db']
    params:
        annot_ver = config['ref']['gtf_ver'],
        max_frac_a = config['talon']['max_frac_a'],
        min_count = config['talon']['min_count'],
        min_datasets = config['talon']['min_datasets']
    output:
        pass_list = config['talon']['pass_list']

use rule talon_filtered_abundance as talon_filt_ab_run with:
    input:
        db = config['talon']['db'],
        pass_list = config['talon']['pass_list']
    params:
        opref = config['talon']['filt_ab'].rsplit('_talon', maxsplit=1)[0],
        genome_ver = config['ref']['fa_ver'],
        annot_ver = config['ref']['gtf_ver']
    output:
        ab = config['talon']['filt_ab']

use rule talon_gtf as talon_gtf_run with:
    input:
        db = config['talon']['db'],
        pass_list = config['talon']['pass_list']
    params:
        opref = config['talon']['gtf'].rsplit('_talon', maxsplit=1)[0],
        genome_ver = config['ref']['fa_ver'],
        annot_ver = config['ref']['gtf_ver']
    output:
        gtf = config['talon']['gtf']

################################################################################
################################### LAPA #######################################
################################################################################
rule lapa_config:
    input:
        bams = lambda wc:get_cfg_entries(wc, df, config['merge']['sort_bam'])
    resources:
        threads = 1,
        mem_gb = 2
    output:
        cfg = config['lapa']['config']
    run:
        temp = get_cfg_entries(wildcards, df, config['merge']['bam'], return_df=True)
        temp = temp[['sample', 'dataset', 'file']].copy(deep=True)
        temp.columns = ['sample', 'dataset', 'path']
        temp.to_csv(output.cfg, sep=',', index=False)

use rule lapa_call_ends as lapa_call_ends_run with:
        input:
            config = config['lapa']['config'],
            fa = config['ref']['fa'],
            gtf = config['ref']['gtf_utr'],
            chrom_sizes = config['ref']['chrom_sizes']
        params:
            opref = config['lapa']['ends'].rsplit('/', maxsplit=1)[0]+'/',
            lapa_cmd = lambda wc:get_lapa_settings(wc,
                                    df,
                                    config['lapa']['ends'],
                                    'lapa_cmd'),
            lapa_end_temp = lambda wc:get_lapa_settings(wc,
                                df,
                                config['lapa']['ends'],
                                'temp_file')
        output:
            ends = config['lapa']['ends']

use rule lapa_link as lapa_link_run with:
    input:
        annot = config['talon']['annot'],
        tss = expand(config['lapa']['ends'], end_mode='tss', allow_missing=True)[0],
        tes = expand(config['lapa']['ends'], end_mode='tes', allow_missing=True)[0]
    params:
        tss_dir = expand(config['lapa']['ends'], end_mode='tss', allow_missing=True)[0].rsplit('/', maxsplit=1)[0]+'/',
        tes_dir = expand(config['lapa']['ends'], end_mode='tes', allow_missing=True)[0].rsplit('/', maxsplit=1)[0]+'/'
    output:
        links = config['lapa']['links']

use rule lapa_correct_talon as lapa_correct_talon_run with:
    input:
        gtf = config['talon']['gtf'],
        filt_ab = config['talon']['filt_ab'],
        annot = config['talon']['annot'],
        links = config['lapa']['links']
    output:
        gtf = config['lapa']['corrected']['gtf'],
        filt_ab = config['lapa']['corrected']['filt_ab']

use rule lapa_filt as lapa_filt_run with:
    input:
        filt_ab = config['lapa']['corrected']['filt_ab'],
        gtf = config['lapa']['corrected']['gtf']
    params:
        t_novs = config['lapa']['filt']['t_novs'],
        g_novs = config['lapa']['filt']['g_novs'],
        filt_spikes = config['lapa']['filt']['remove_spikes']
    output:
        filt_list = config['lapa']['filt']['pass_list']

use rule lapa_filt_ab as lapa_filt_ab_run with:
    input:
        ab = config['lapa']['corrected']['filt_ab'],
        filt_list = config['lapa']['filt']['pass_list']
    output:
        ab = config['lapa']['filt']['filt_ab']

use rule lapa_filt_gtf as lapa_filt_gtf_run with:
    input:
        gtf = config['lapa']['corrected']['gtf'],
        filt_list = config['lapa']['filt']['pass_list']
    output:
        gtf = config['lapa']['filt']['gtf']

################################################################################
################################# Cerberus #####################################
################################################################################

use rule cerb_gtf_to_bed as cerb_get_gtf_ends with:
    input:
        gtf = config['lapa']['filt']['gtf']
    output:
        ends = config['cerberus']['ends']
    params:
        slack = lambda wc:config['cerberus'][wc.end_mode]['slack'],
        dist = lambda wc:config['cerberus'][wc.end_mode]['dist']

use rule cerb_gtf_to_ics as cerb_get_gtf_ics with:
    input:
        gtf = config['lapa']['filt']['gtf']
    output:
        ics = config['cerberus']['ics']

use rule cerberus_agg_ics as cerb_agg_ics_first with:
    input:
        ref_ics = config['ref']['cerberus']['ics'],
        ics = config['cerberus']['ics']
    params:
        ref = False,
        sources = lambda wc:['cerberus', get_df_col(wc, df, 'source')]
    output:
        ics = config['cerberus']['agg']['ics']

use rule cerberus_agg_ics as cerb_agg_ics_seq with:
    input:
        ref_ics = lambda wc: get_prev_cerb_entry(wc, df, config['cerberus']['agg']['ics']),
        ics = config['cerberus']['ics']
    params:
        ref = False,
        sources = lambda wc:['cerberus', get_df_col(wc, df, 'source')]
    output:
        ics = config['cerberus']['agg']['ics']

use rule cerb_agg_ends as cerb_agg_ends_first with:
    input:
        ref_ends = config['ref']['cerberus']['ends'],
        ends = config['cerberus']['ends']
    params:
        add_ends = True,
        ref = False,
        slack = lambda wc:config['cerberus']['agg'][wc.end_mode]['slack'],
        sources = lambda wc:['cerberus', get_df_col(wc, df, 'source')]
    output:
        ends = config['cerberus']['agg']['ends']

use rule cerb_agg_ends as cerb_agg_ends_seq with:
    input:
        ref_ends = lambda wc: get_prev_cerb_entry(wc, df, config['cerberus']['agg']['ends']),
        ends = config['cerberus']['ends']
    params:
        add_ends = True,
        ref = False,
        slack = lambda wc:config['cerberus']['agg'][wc.end_mode]['slack'],
        sources = lambda wc:['cerberus', get_df_col(wc, df, 'source')]
    output:
        ends = config['cerberus']['agg']['ends']

use rule cerb_write_ref as cerb_write_ref_run with:
    input:
        ic = config['cerberus']['agg']['ics'],
        tss = lambda wc:expand(get_cfg_entries(wc,
                        df,
                        config['cerberus']['agg']['ends']),
                        end_mode='tss')[0],
        tes = lambda wc:expand(get_cfg_entries(wc,
                        df,
                        config['cerberus']['agg']['ends']),
                        end_mode='tes')[0]
    output:
        h5 = config['cerberus']['ca']

use rule cerb_annot as cerb_annot_ref with:
    input:
        h5 = config['ref']['cerberus']['ca'],
        gtf = config['ref']['gtf']
    params:
        source = config['ref']['gtf_ver'],
        gene_source = None
    output:
        h5 = config['ref']['cerberus']['ca_annot']

use rule cerb_annot as cerb_annot_run with:
    input:
        h5 = config['cerberus']['ca'],
        gtf = config['lapa']['filt']['gtf']
    params:
        source = lambda wc:get_df_col(wc, df, 'source'),
        gene_source = None
    output:
        h5 = config['cerberus']['ca_annot']

#
use rule cerb_gtf_ids as cerb_update_ref_gtf with:
    input:
        h5 = config['ref']['cerberus']['ca_annot'],
        gtf = config['ref']['gtf']
    params:
        source = config['ref']['gtf_ver'],
        update_ends = True,
        agg = True
    output:
        gtf = config['ref']['cerberus']['gtf']

use rule cerb_gtf_ids as cerb_update_gtf with:
    input:
        h5 = config['cerberus']['ca_annot'],
        gtf = config['lapa']['filt']['gtf']
    params:
        source = lambda wc:get_df_col(wc, df, 'source'),
        update_ends = True,
        agg = True
    output:
        gtf = config['cerberus']['gtf']

use rule cerb_ab_ids as study_cerb_ab with:
    input:
        h5 = config['cerberus']['ca_annot'],
        ab = config['lapa']['filt']['filt_ab']
    params:
        source = lambda wc:get_df_col(wc, df, 'source'),
    output:
        ab = config['cerberus']['ab']
