# Output Report for Model Compression exploration

The examples below show the **table format** (column order, Unicode box style, value formatting). The **number of rows** is governed by SKILL.md's selection rule: exactly 5 representative configs per group spanning the accuracy-vs-size tradeoff, picked from the JSONL after filtering errors and configs below the quality floor. Some examples below show fewer than 5 rows — that's only because the snippet was abbreviated.

Example output report:

```text
  Group 1: Per-Channel Quantization

  ┌────────────────────────────────┬───────────┬──────────────┬───────────────────┐
  │             Config             │ PSNR (dB) │ Avg Bitwidth │ Compression Ratio │
  ├────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perchannel_int8_symmetric      │ 57.59     │ 8.04         │ 1.99x             │
  ├────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perchannel_int4_symmetric_skip │ 31.61     │ 4.23         │ 3.78x             │
  ├────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perchannel_int4_symmetric      │ 30.41     │ 4.04         │ 3.96x             │
  └────────────────────────────────┴───────────┴──────────────┴───────────────────┘


  Group 2: Per-Block Quantization

  ┌───────────────────────────────────┬───────────┬──────────────┬───────────────────┐
  │              Config               │ PSNR (dB) │ Avg Bitwidth │ Compression Ratio │
  ├───────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perblock_bs32_int8_symmetric      │ 62.71     │ 9.00         │ 1.78x             │
  ├───────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perblock_bs64_int8_symmetric      │ 62.36     │ 8.50         │ 1.88x             │
  ├───────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perblock_bs128_int8_symmetric     │ 61.31     │ 8.25         │ 1.94x             │
  ├───────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perblock_bs64_int4_symmetric_skip │ 36.03     │ 4.68         │ 3.42x             │
  ├───────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ perblock_bs64_int4_symmetric      │ 35.33     │ 4.50         │ 3.56x             │
  └───────────────────────────────────┴───────────┴──────────────┴───────────────────┘

  Group 3: Palettization

  ┌──────────────────────────────────┬───────────┬──────────────┬───────────────────┐
  │              Config              │ PSNR (dB) │ Avg Bitwidth │ Compression Ratio │
  ├──────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ palette_pertensor_8bit           │ 59.39     │ 8.01         │ 2.00x             │
  ├──────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ palette_perchannel_4bit_pcs_skip │ 40.77     │ 4.54         │ 3.53x             │
  ├──────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ palette_perchannel_4bit_skip     │ 40.36     │ 4.52         │ 3.54x             │
  ├──────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ palette_grouped_gs4_4bit         │ 38.95     │ 4.08         │ 3.92x             │
  ├──────────────────────────────────┼───────────┼──────────────┼───────────────────┤
  │ palette_perchannel_4bit_pcs      │ 38.63     │ 4.35         │ 3.67x             │
  └──────────────────────────────────┴───────────┴──────────────┴───────────────────┘
```

When including configs that have layer skipping, mention the skipped layer type(s) or layer name(s)
