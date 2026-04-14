-- migrations/013_synth_start_sec.sql
-- Store the actual start position of each synthesized segment in the dubbed audio.
-- Original start_sec/end_sec are from the source audio; the assembler cursor-places
-- clips at shifted positions, so we need synth_start_sec for accurate subtitle sync.

ALTER TABLE dub_segment_translations
  ADD COLUMN IF NOT EXISTS synth_start_sec FLOAT;
