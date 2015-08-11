#!/usr/bin/env nextflow


params.reference = 'data/genome.fasta'
params.scaffoldmin = 1000 // Minimum scaffold size to consider
params.minsize = 100 // Minimum exon size
params.species = 'fungi' // Name of species passed to RepeatMasker
params.maxintronlength = 500 // Maximum intron length
params.bamfiles = 'data/bams/*.bam'
params.pasaconf = 'conf/alignAssembly.conf' // Pasa configuration file to set db name etc.
params.leftreads = 'data/reads/left.fastq'
params.rightreads = 'data/reads/right.fastq'
reference_raw = file(params.reference)

// Remove small scaffolds from analysis.
process remove_small_scaffolds {
  container 'genomicpariscentre/bioperl:1.6.924'
  
  input:
  file 'ref.fasta' from reference_raw

  output:
  file 'ref_trimmed.fasta' into ref_trimmed_for_orfs
  file 'ref_trimmed.fasta' into ref_trimmed_for_masking
  file 'ref_trimmed.fasta' into ref_trimmed_for_softmasking
  file 'ref_trimmed.fasta' into ref_trimmed_for_trinity
  file 'ref_trimmed.fasta' into ref_trimmed_for_bamtohints
  file 'ref_trimmed.fasta' into ref_trimmed_for_pasa

  "trim_fasta_all.pl -i ref.fasta -out ref_trimmed.fasta -length ${params.scaffoldmin}"
}

// Generate a fasta file of open reading frames.
process identify_orfs {
  container 'robsyme/emboss'
  
  input: 
  file 'ref.fasta' from ref_trimmed_for_orfs

  output:
  file 'ref_exons.aa' into orfs_fasta
  
  "getorf -sequence ref.fasta -outseq ref_exons.aa -minsize 300 -find 0"
}

// We want to remove ORFs with a high percentage of Xs. Notice that
// the large orfs file is split into pieces containing 1000 fasta
// entries each.
process remove_Xs {
  container 'robsyme/bioruby'

  input: 
  file 'orfs.fasta' from orfs_fasta.splitFasta( by: 5000 )

  output:
  stdout into clean_orfs_for_transposons
  stdout into clean_orfs_for_fungi

  """
#!/usr/bin/env ruby

require 'bio'
Bio::FlatFile.open('orfs.fasta').each do |entry|
  next if entry.length < (${params.minsize} / 3)
  x_percentage = entry.seq.composition['X'] / entry.length.to_f
  puts entry if x_percentage < 0.3
end
"""
}

// Run HHblits to identify potential transposons in the (cleaned) open
// reading frames from the 'identify_orfs' step. We run a hhblits
// process for each open reading frame.
process hhblits_transposon {
  container 'robsyme/hhblits-transposon'
  
  input:
  file 'orfs.fasta' from clean_orfs_for_transposons.splitFasta( by: 1000 )

  output:
  stdout into hhblits_transposon

  """
samtools faidx orfs.fasta
for id in `cut -f1 orfs.fasta.fai`; do
  samtools faidx orfs.fasta \$id\
  | hhblits -i stdin -o stdout -d /databases/transposons -e 1e-5 -E 1e-5 -id 80 -n 2
done
"""
}

process hhblits_fungi {
  container 'robsyme/hhblits-fungi'
  
  input:
  file 'orf.fasta' from clean_orfs_for_fungi.splitFasta( by: 1000 )

  output:
  stdout into hhblits_fungi

"""
samtools faidx orfs.fasta
for id in `cut -f1 orfs.fasta.fai`; do
  samtools faidx orfs.fasta \$id \
  | hhblits -i stdin -o stdout -d /databases/fungal_50kclus -e 1e-5 -E 1e-5 -id 80 -n 2
done
"""
}

//Look at a hhblits output file and generate a gff file of the matches
process parse_transposon_hhr {
  cache 'deep'

  input:
  file 'search.hhr' from hhblits_transposon.collectFile()

  output:
  file 'out.gff3' into hhblits_transposon_gff

  """
parse_hhr.rb \
--homology_cutoff 70 \
--evalue_cutoff 1e-3 \
--pvalue_cutoff 1e-5 \
--score_cutoff 100 \
--align_length_cutoff 50 \
--template_length_cutoff 30 \
--repeat \
search.hhr
"""
}

process parse_fungi_hhr {
  cache 'deep'

  input:
  file 'search.hhr' from hhblits_fungi.collectFile()

  output:
  file 'out.gff3' into hhblits_fungi_gff

  """
parse_hhr.rb \
--homology_cutoff 70 \
--evalue_cutoff 1e-3 \
--pvalue_cutoff 1e-5 \
--score_cutoff 100 \
--align_length_cutoff 50 \
--template_length_cutoff 30 \
search.hhr
"""
}

process repeatmasker {
  container 'repeatmasker'

  input:
  file 'ref.fasta' from ref_trimmed_for_masking

  output:
  file 'ref.fasta.out.gff' into repeats_gff_for_hints
  file 'ref.fasta.out.gff' into repeats_gff_for_softmasking
  file 'ref.fasta.masked' into ref_masked_for_golden

  "RepeatMasker -qq -frag 5000000 -gff -species ${params.species} -no_is ref.fasta"
}

process repeatmasker_gff_to_hints {
  container 'robsyme/bioruby'

  input:
  file 'repeats.gff' from repeats_gff_for_hints

  output:
  stdout into repeat_hints
  
  '''
#!/usr/bin/env ruby
repeats = File.open("repeats.gff", "r")

while repeats.gets
  next if $_ =~ /^#/
  split = $_.split("\t")
  split[2] = "nonexonpart"
  split[8] = "src=RM;pri=6"
  puts split.join("\t")
end
'''
}

process softMaskReference {
  container 'robsyme/bedtools'

  input:
  file 'ref.fasta' from ref_trimmed_for_softmasking
  file 'repeats.gff' from repeats_gff_for_softmasking

  output:
  file 'ref_softmasked.fasta' into ref_softmasked_for_golden

  "maskFastaFromBed -soft -fi ref.fasta -fo ref_softmasked.fasta -bed repeats.gff"
}

process merge_bams {
  input:
  file '*.bam' from Channel.fromPath(params.bamfiles).toList()

  output:
  file 'merged.bam' into mapped_reads
  file 'merged.bam' into mapped_reads_for_bamtohints

  "samtools merge merged.bam *.bam"
}

process split_bams_by_scaffold {
  input:
  file 'merged.bam' from mapped_reads

  output:
  file '*.bam' into split_bams

  """
samtools index merged.bam && \
samtools idxstats merged.bam \
| awk '\$3 > 0 && \$2 > ${params.scaffoldmin} {print \$1}' \
| xargs -n1 -I{} samtools view -b -o {}.bam merged.bam {}
"""
}

process genome_guided_trinity {
  container 'robsyme/trinity'
  
  input:
  set 'ref.fasta', 'single.bam' from ref_trimmed_for_trinity.spread(split_bams)

  output:
  file 'trinity_out_dir/Trinity-GG.fasta' into genome_guided_trinity_split
  
  "Trinity --genome_guided_bam single.bam --genome_guided_max_intron ${params.maxintronlength} --max_memory 2G --jaccard_clip --CPU 1 --full_cleanup"
}

process collate_genome_guided_transcripts {
  input:
  stdin genome_guided_trinity_split.collectFile().map{ it.text }

  output:
  stdout into genome_guided_trinity
  
  '''
#!/usr/bin/awk -f
/^>/ {
  sub(/>GG[0-9]+/, ">GG" count++)
  print
}

/^[^>]/ {
  print $0
}
'''
}

process denovo_trinity {
  container 'robsyme/trinity'

  input:
  file 'left.fastq' from file(params.leftreads)
  file 'right.fastq' from file(params.rightreads)
  
  output:
  file 'trinity_out_dir.Trinity.fasta' into denovo_trinity

  "Trinity --seqType fq --left left.fastq --right right.fastq --max_memory 2G --CPU 2 --jaccard_clip --full_cleanup"
}

process bam_to_hints {
  container 'robsyme/bedtools'
  
  input:
  file 'ref.fasta' from ref_trimmed_for_bamtohints
  file 'all.bam' from mapped_reads_for_bamtohints

  output:
  file 'all.bam.junctions.hints' into augustus_hints
  
  "augustus_RNAseq_hints.pl --genome ref.fasta --bam all.bam"
}


// Note that I had to start a separate mysql docker container: docker
// run --name pasadb -e MYSQL_ROOT_PASSWORD=password -e MYSQL_DATABASE=pasa -e MYSQL_USER=pasauser -e MYSQL_PASSWORD=password mysql
process pasa {
  container 'robsyme/pasa'

  input:
  file 'GG_raw.fasta' from genome_guided_trinity
  file 'DN_raw.fasta' from denovo_trinity
  file 'ref.fasta' from ref_trimmed_for_pasa
  file 'alignAssembly.config' from file(params.pasaconf)

  output:
  file '*.assemblies.fasta.transdecoder.gff3' into pasa_gff3_for_golden
  file '*.assemblies.fasta.transdecoder.pep' into pasa_pep_for_golden
  file '*.assemblies.fasta.transdecoder.cds' into pasa_cds_for_golden
  file '*.assemblies.fasta.transdecoder.genome.gff3' into pasa_genomegff_for_golden
  file '*.assemblies.fasta' into pasa_fasta_for_golden

  """
grep '^>' DN_raw.fasta          \
| awk '{print(substr(\$1, 2))}' \
> DN_raw.list

cat DN_raw.fasta GG_raw.fasta > transcripts.fasta

/opt/pasa/scripts/Launch_PASA_pipeline.pl       \
  -c alignAssembly.config                       \
  --MAX_INTRON_LENGTH ${params.maxintronlength} \
  --stringent_alignment_overlap 30.0            \
  -C                                            \
  -r                                            \
  -R                                            \
  -g ref.fasta                                  \
  -t transcripts.fasta                          \
  --TDN DN_raw.list                             \
  --ALIGNERS blat,gmap                          \
  --TRANSDECODER                                \
  --CPU 2

/opt/pasa/scripts/build_comprehensive_transcriptome.dbi \
-c ../../../alignAssembly.config                        \
-t transcripts.fasta                                    \
--min_per_ID 95                                         \
--min_per_aligned 30

/opt/pasa/scripts/pasa_asmbls_to_training_set.dbi \
--pasa_transcripts_fasta *.assemblies.fasta       \
--pasa_transcripts_gff3 *.pasa_assemblies.gff3
"""
}


pasa_genomegff_for_golden.subscribe{ println("GOLDEN_GFF: $it") }

debug.subscribe{ println("DEBUG: $it") }
