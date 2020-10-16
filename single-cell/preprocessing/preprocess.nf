#!/usr/bin/env nextflow
//Define input channels
count_dirs = Channel.fromPath(params.input.count_dir)
sample_list = Channel.from(params.input.sample_list)
nmad_val = Channel.from(params.preprocess.nmads)
gex_metadata = Channel.fromPath(params.processmeta.gex_metadata)
vdj_metadata = Channel.fromPath(params.processmeta.vdj_metadata)
vdj_meta = Channel.from(params.processmeta.vdj)
//Load counts from cellranger output and filter out low quality cells
process QCFilter {
  echo false
  module 'R/4.0.2-foss-2019b'
  label 'low_mem'
  input:
    val count_dir from count_dirs
    each sample from sample_list
    path meta_file from gex_metadata
    val nmad from nmad_val

  output:
    path "${sample}_sce.rds" into sce_obj
    path "${sample}_sce_raw.rds" into sce_raw

  script:
    """
    #!/usr/bin/env Rscript
    library(scran)
    library(scater)
    #library(Seurat)
    library(tidyverse)
    library(DropletUtils)
    set.seed(12357)
    ## Load metadata and grab metadata information
    meta <- read_csv("${meta_file}") %>% 
            filter(library_id == "${sample}" & str_detect(locus, "GEX"))
    library_id <- meta %>%
                  pull(library_id) %>%
                  unique()
    ## Load in sample data
    sce <- read10xCounts(paste("${count_dir}", library_id, "outs", "filtered_feature_bc_matrix", sep="/"))
    sce\$Sample <- "${sample}"
    ## Add metadata to colData
    saveRDS(sce, "${sample}_sce_raw.rds")
    ## Quantify number of cells with low library size, gene count and high mitochondrial expression
    is_mito <- grepl(rowData(sce)\$Symbol, 
                     pattern= "^MT-")
    qc_df <- perCellQCMetrics(sce, 
                              subsets=list(mitochondrial= is_mito))
    discard <- quickPerCellQC(qc_df, 
                              percent_subsets=c("subsets_mitochondrial_percent"), 
                              nmad=${nmad}) 
    qc_tibble <- qc_df %>% 
                 as_tibble() %>% 
                 rowid_to_column()
    discard_tibble <- discard %>% 
                      as_tibble() %>% 
                      rowid_to_column() %>% 
                      dplyr::select(rowid, discard)
    qc_tibble <- left_join(qc_tibble, discard_tibble, by = "rowid") %>% 
                 dplyr::mutate(sample = "${sample}")
    ## Filter low QC cells
    sce <- sce[,!discard\$discard]
    is_mito <- grepl(rowData(sce)\$Symbol, 
                     pattern= "^MT-")
    flt_qc_df <- perCellQCMetrics(sce, 
                                  subsets=list(mitochondrial= is_mito))
    ## Load metadata and grab metadata information
    lib_info <- colData(sce) %>% 
                as_tibble()
    lib_info <- left_join(lib_info, meta, by = c("Sample"  = "library_id"))
    ## Add metadata to CDS object for reanalysis
    metadata(sce)\$perCellQCMetrics_raw <- qc_df
    metadata(sce)\$quickPerCellQC_raw <- discard
    metadata(sce)\$perCellQCMetrics_filtered <- flt_qc_df
    metadata(sce)\$study_info <- lib_info
    metadata(sce)\$Sample <- "${sample}"
    metadata(sce)\$meta <- meta
    ## Save RDS file
    saveRDS(sce, "${sample}_sce.rds")
    """
}    
//Add VDJ data when available
process VDJMetadata {
  echo false
  module 'R/4.0.2-foss-2019b'
  label "low_mem"

  input:
    each sce from sce_obj
    //val vdj from vdj_meta
    path meta_file from vdj_metadata
    
  output:
    path "${sce.getName()}" into asce_obj

  script:
  sample = sce.getSimpleName() 
  if( "$params.processmeta.vdj" != false )
    """
    #!/usr/bin/env Rscript
    library(scran)
    library(scater)
    library(tidyverse)
    library(DropletUtils)
    set.seed(12357)  
    sce <- readRDS("${sce}")
    vdj <- read_csv("${meta_file}") %>% 
           filter(sampleName == metadata(sce)\$Sample & str_detect(locus, "VDJ"))
    vdj_table <- colData(sce) %>% 
                 as_tibble() %>%
                 mutate(id_barcode = str_extract(Barcode, "[ACGT]+"),
                        repertoire_id = metadata(sce)\$Sample)

    if (dim(vdj)[1] == 0) {
      metadata(sce)\$vdj_table <- NULL
    } else {
      metadata(sce)\$vdj_table <- vdj_table
    }
    saveRDS(sce, "${sce.getName()}")
    """

  else if( "$params.processmeta.vdj" == false )
    """
    #!/usr/bin/env Rscript
    library(scran)
    library(scater)
    library(tidyverse)
    library(DropletUtils)
    set.seed(12357)  
    sce <- readRDS("${sce}")
    metadata(sce)\$doublet_barcode <- NULL
    metadata(sce)\$vdj_raw <- NULL
    saveRDS(sce, "${sce.getName()}")
    """
}
//Duplicate channels that contain annotated SCE objects
asce_obj.into{sce_write; sce_plotQC; sce_plotVDJ}
// Wtite SCE objects into different formats including monocle3, Seurat and 10X count matrix
process writeSCE{
  echo false
  module 'R/4.0.2-foss-2019b'
  module 'monocle3/0.2.2-foss-2019b-R-4.0.2'
  publishDir "$params.output.folder/Preprocess/CDS", mode : "move"
  label 'local'
  input:
    each sce from sce_write
  output:
    path "${sample}_sce.rds" into sce_out
    path "${sample}_filtered_matrix" into mtx_obj
    path "${sample}_filtered_monocle3_cds.rds" into mon_obj

  script:
    sample = sce.getSimpleName() - ~/_sce$/
    """
    #!/usr/bin/env Rscript
    library(scran)
    library(scater)
    library(monocle3)
    #library(Seurat)
    library(tidyverse)
    library(DropletUtils)
    set.seed(12357)

    sce <- readRDS("${sce}")
    #Write SCE matrix
    saveRDS(sce, "${sample}_sce.rds")
    #Write count matrix
    write10xCounts("${sample}_filtered_matrix", counts(sce), barcodes = sce\$Barcode, 
                   gene.id=rownames(sce), gene.symbol=rowData(sce)\$Symbol)
    #Write monocle CDS
    cell_metadata <- colData(sce) %>% 
                     as_tibble()
    study_metadata <- metadata(sce)\$meta
    cell_metadata <- left_join(cell_metadata, study_metadata, by = c("Sample" = "library_id")) %>%
                     as.data.frame()
    row.names(cell_metadata) <- cell_metadata\$Barcode
    gene_metadata <- rowData(sce)
    colnames(gene_metadata) <- c("ID", "gene_short_name", "Type")
    matrix <- counts(sce)
    cds <- new_cell_data_set(matrix, cell_metadata=cell_metadata, gene_metadata=gene_metadata)
    metadata(cds)\$vdj_table <- metadata(sce)\$vdj_table
    metadata(cds)\$Sample <- "${sample}"
    saveRDS(cds, "${sample}_filtered_monocle3_cds.rds")
    #Write Seurat CDS
    #counts <- assay(sce, "counts")
    #libsizes <- colSums(counts)
    #size.factors <- libsizes/mean(libsizes)
    #logcounts(sce) <- as.matrix(log2(t(t(counts)/size.factors) + 1))
    #colnames(sce) <- sce\$Barcode
    #seu_cds <- as.Seurat(sce, counts = "counts", data = "logcounts")
    #Misc(seu_cds, slot="perCellQCMetrics") <- metadata(sce)\$perCellQCMetrics_filtered
    ##Misc(seu_cds, slot="study_info") <- metadata(sce)\$study_info
    #Misc(seu_cds, slot="doublet_barcode") <- metadata(sce)\$doublet_barcode
    #Misc(seu_cds, slot="vdj_raw") <- metadata(sce)\$vdj_raw
    #Misc(seu_cds, slot="vdj_raw_keys") <- metadata(sce)\$vdj_raw_keys
    #saveRDS(seu_cds, "${sample}_filtered_seurat_cds.rds")
    """    
}
// Summarize and plot sample QC results from the study
process PlotQC {
  echo false
  label 'local'
  publishDir "$params.output.folder/Preprocess/QCReports", mode : 'move'
  module 'R/4.0.2-foss-2019b'
  input:
    val raw_cds_list from sce_raw.collect()
    val flt_cds_list from sce_plotQC.collect()
  output:
    path "QC_fail_summary.csv" into discard_report
    path "Knee_plot.png" into knee_grid
    path "Percent_mito_plot.png" into mito_grid
    path "Raw_count_plot.png" into raw_count
    path "Filtered_count_plot.png" into flt_count
    path "Raw_gex_plot.png" into raw_gex
    path "Filtered_gex_plot.png" into flt_gex
    path "Study_summary.png" into study_summary
  
  """
  #!/usr/bin/env Rscript
  library(scran)
  library(scater)
  library(ggplot2)
  library(patchwork)
  library(tidyverse)
  library(DropletUtils)
  set.seed(12357)
  raw_cds_list <- c("${raw_cds_list.join('\",\"')}")
  filtered_cds_list <- c("${flt_cds_list.join('\",\"')}")
  getDiscardSummary <- function(cds_file) {
    cds <- readRDS(cds_file)
    discard <- metadata(cds)\$quickPerCellQC_raw
    discard_summary <- discard %>% as_tibble() %>% 
                       summarize(low_lib_size = sum(low_lib_size), low_n_features = sum(low_n_features), 
                                 high_subsets_mitochondrial_percent = sum(high_subsets_mitochondrial_percent), discard = sum(discard)) %>% 
                       add_column(sample = metadata(cds)\$Sample)
    return(discard_summary)
  }
  discard_summary <- filtered_cds_list %>% map(getDiscardSummary) %>% reduce(rbind)
  write_csv(discard_summary, "QC_fail_summary.csv")

  getKneePlots <- function(cds_file) {
    cds <- readRDS(cds_file)
    sample <- metadata(cds)\$Sample
    bcrank <- barcodeRanks(counts(cds))
    uniq <- !duplicated(bcrank\$rank)
    kneeplot <- ggplot(as_tibble(bcrank[uniq, ]), aes(x = rank, y = total)) + geom_point(shape = 21) + coord_trans(x="log2", y="log2") + geom_hline(aes(yintercept = metadata(bcrank)\$inflection, linetype = "Inflection"),  colour = "darkgreen") + geom_hline(aes(yintercept = metadata(bcrank)\$knee, linetype = "Knee"),  colour = "dodgerblue") + theme_classic() + scale_linetype_manual(name = "Threshold", values = c(2, 2), guide = guide_legend(override.aes = list(color = c("darkgreen", "dodgerblue")))) + xlab("Rank") + ylab("Total UMI count") + ggtitle(sample) + theme(plot.title = element_text(hjust = 0.5))
    return(kneeplot)
  }
  knee_grid <- raw_cds_list %>% map(getKneePlots) %>% wrap_plots() + plot_layout(guides = 'collect')
  ggsave("Knee_plot.png", plot = knee_grid, device = "png", width = 42, height = 42, units = "cm", dpi="retina")

  getMitoPlots <- function(filtered_file) {
    flt_cds <- readRDS(filtered_file)
    sample <- metadata(flt_cds)\$Sample
    raw_cds.qc <- metadata(flt_cds)\$perCellQCMetrics_raw %>% as_tibble()
    raw_discard <- isOutlier(raw_cds.qc\$subsets_mitochondrial_percent, type="higher")
    rawplot <-  ggplot(raw_cds.qc, aes(x=`sum`, y= `subsets_mitochondrial_percent`)) + geom_point(shape=21) + coord_trans(x = "log2") + geom_hline(aes(yintercept = attr(raw_discard, "thresholds")["higher"]), colour = "red") + theme_classic() + xlab("Total count") + ylab("Mitochondrial %") + ggtitle(paste(sample, "raw")) + theme(plot.title = element_text(hjust = 0.5))
    flt_cds.qc <- metadata(flt_cds)\$perCellQCMetrics_filtered %>% as_tibble()
    flt_discard <- isOutlier(flt_cds.qc\$subsets_mitochondrial_percent, type="higher")
    fltplot <-  ggplot(flt_cds.qc, aes(x=`sum`, y= `subsets_mitochondrial_percent`)) + geom_point(shape=21) + coord_trans(x = "log2") + geom_hline(aes(yintercept = attr(flt_discard, "thresholds")["higher"]), colour = "red") + theme_classic() + xlab("Total count") + ylab("Mitochondrial %") + ggtitle(paste(sample, "filtered")) + theme(plot.title = element_text(hjust = 0.5))
    patched <- rawplot + fltplot
    return(patched)
  }
  mito_grid <-  filtered_cds_list %>% map(getMitoPlots) %>% wrap_plots() 
  ggsave("Percent_mito_plot.png", plot = mito_grid, device = "png", width = 42, height = 42, units = "cm", dpi="retina")

  getAvgCounts <- function(cds_file) {
    cds <- readRDS(cds_file)
    raw_cds_qc <- metadata(cds)\$perCellQCMetrics_raw %>% as_tibble()
    raw_median_count <- median(raw_cds_qc\$sum)
    raw_median_genes <- median(raw_cds_qc\$detected)
    raw_n_cells <- nrow(raw_cds_qc)
    flt_cds_qc <- metadata(cds)\$perCellQCMetrics_filtered %>% as_tibble()
    flt_median_count <- median(flt_cds_qc\$sum)
    flt_median_genes <- median(flt_cds_qc\$detected)
    flt_n_cells <- nrow(flt_cds_qc)
    sample <- metadata(cds)\$Sample
    raw_count_tibble = tibble(sample = sample, ncells = raw_n_cells, median_count = raw_median_count, median_genes = raw_median_genes, type = "raw")
    flt_count_tibble = tibble(sample = sample, ncells = flt_n_cells, median_count = flt_median_count, median_genes = flt_median_genes, type = "flt")
    count_tibble <- bind_rows(raw_count_tibble, flt_count_tibble)
    return(count_tibble)
  }

  study_table <- filtered_cds_list %>% map(getAvgCounts) %>% reduce(rbind)
  study_raw_tibble <- study_table %>% filter(type == "raw")
  study_flt_tibble <- study_table %>% filter(type == "flt")
  raw_count <- ggplot(study_raw_tibble, aes(x=median_count, y=ncells, color = `sample`)) + geom_point(alpha=0.8, size=3, shape="square") + coord_flip() + theme_classic() + xlab("Median count per cell") + ylab("Estimated number of cells") + labs(colour = "Sample") + ggtitle("Raw count distribution") + expand_limits(x = 0, y = 0) + theme(plot.title = element_text(hjust = 0.5))
  flt_count <- ggplot(study_flt_tibble, aes(x=median_count, y=ncells, color = `sample`)) + geom_point(alpha=0.8, size=3, shape="square") + coord_flip() + theme_classic() + xlab("Median count per cell") + ylab("Estimated number of cells") + labs(colour = "Sample") + ggtitle("Filtered count distribution") + expand_limits(x = 0, y = 0) + theme(plot.title = element_text(hjust = 0.5))
  raw_gene <- ggplot(study_raw_tibble, aes(x=median_genes, y=ncells, color = `sample`)) + geom_point(alpha=0.8, size=3, shape="square") + coord_flip() + theme_classic() + xlab("Median genes expressed per cell") + ylab("Estimated number of cells") + labs(colour = "Sample") + ggtitle("Raw gene expression distribution") + expand_limits(x = 0, y = 0) + theme(plot.title = element_text(hjust = 0.5))
  flt_gene <- ggplot(study_flt_tibble, aes(x=median_genes, y=ncells, color = `sample`)) + geom_point(alpha=0.8, size=3, shape="square") + coord_flip() + theme_classic() + xlab("Median genes expressed per cell") + ylab("Estimated number of cells") + labs(colour = "Sample") + ggtitle("Raw gene expression distribution") + expand_limits(x = 0, y = 0) + theme(plot.title = element_text(hjust = 0.5))
  grid_plot <- (raw_count | flt_count) / (raw_gene | flt_gene)
  ggsave("Raw_count_plot.png", plot = raw_count, device = "png", width = 15, height = 15, units = "cm", dpi="retina") 
  ggsave("Filtered_count_plot.png", plot = flt_count, device = "png", width = 15, height = 15, units = "cm", dpi="retina") 
  ggsave("Raw_gex_plot.png", plot = raw_gene, device = "png", width = 15, height = 15, units = "cm", dpi="retina") 
  ggsave("Filtered_gex_plot.png", plot = flt_gene, device = "png", width = 15, height = 15, units = "cm", dpi="retina") 
  ggsave("Study_summary.png", plot =grid_plot, device = "png", width = 30, height = 30, units = "cm", dpi="retina") 
  """
}


/*process plotVDJ {
  echo false
  publishDir "$params.output.folder/Preprocess/QCReports", mode : 'move'
  module 'R/3.6.1-foss-2016b-fh2'
  input:
    val sce from sce_plotVDJ
  output:

  script:  
    """
    #!/usr/bin/env Rscript
    library(scran)
    library(scater)
    library(ggplot2)
    library(patchwork)
    library(tidyverse)
    library(DropletUtils)
    set.seed(12357)


}*/