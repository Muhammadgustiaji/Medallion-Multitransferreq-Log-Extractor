#!/bin/bash

# ============================================================
# MEDALLION MULTITRANSFERREQ REALTIME LOG EXTRACTOR
# Version       : 1.0 - Realtime Extraction + Daily Rotation
# OS            : RHEL 7
# Maintainer    : Project contributors
# Last Update   : 27-10-2026
# ============================================================
#
# DESCRIPTION:
# Extract transaction logs for multiTransferReq from
# medallionConnectorJaxws.log in realtime.
#
# Correlate transaction events based on WebLogic Thread ID:
# 1. WebServiceImpl 110 - aaawebservice
# 2. WebServiceImpl 43  - Outbound
# 3. WebServiceImpl 43  - Inbound
#
# ============================================================
#
# FEATURES:
# - Continuous monitoring using tail -F
# - Extract multiTransferReq transactions
# - Correlate request/response by WebLogic Thread ID
# - Extract aaawebservice, Outbound, and Inbound events
# - Convert multiline XML Inbound into a single line
# - Output three log lines per completed transaction
# - Active log: medallion_multitransferreq.log
# - Archive: medallion_multitransferreq_DDMMYYYY.log
# - Basic event date detection
# - Daily rotation based on incoming event dates
# - Create output directory automatically
# - Flush completed transaction logs immediately
#
# ============================================================
#
# CONFIGURATION
#
# ============================================================

# Path direktori input & output
INPUT_DIR="${INPUT_DIR:-/var/log/example-app/server}"
OUTPUT_DIR="${OUTPUT_DIR:-/var/log/log-extractor/multitransferreq}"

INPUT_LOG="$INPUT_DIR/medallionConnectorJaxws.log"
OUTPUT_LOG="$OUTPUT_DIR/medallion_multitransferreq.log"

# Pastikan folder output multitransferreq sudah dibuat
mkdir -p "$OUTPUT_DIR"

# Monitoring stream via tail -F lalu diproses oleh AWK
tail -n 0 -F "$INPUT_LOG" 2>/dev/null | awk -v outdir="$OUTPUT_DIR" -v active_out="$OUTPUT_LOG" '
BEGIN {
    active_inbound_thread = ""
    timestamp_pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} \\[\\["
    
    # Inisialisasi tanggal hari ini (format YYYY-MM-DD untuk komparasi pergantian hari)
    "date +%Y-%m-%d" | getline current_date
    close("date +%Y-%m-%d")
}

{
    raw_line = $0
    sub(/\r$/, "", raw_line)

    if (raw_line ~ timestamp_pattern) {
        active_inbound_thread = ""

        # Ambil tanggal dari baris log (YYYY-MM-DD)
        log_date = substr(raw_line, 1, 10)

        # Cek jika terjadi pergantian hari
        if (log_date != "" && log_date != current_date) {
            # Format DDMMYYYY untuk backup H-1 (tanggal kemarin)
            cmd_date = "date -d \"" current_date "\" +%d%m%Y"
            cmd_date | getline backup_suffix
            close(cmd_date)

            backup_file = outdir "/medallion_multitransferreq_" backup_suffix ".log"

            # Tutup stream file aktif sebelum di-rename
            close(active_out)

            # Pindahkan file aktif kemarin ke nama backup jika file tidak kosong
            system("if [ -s \"" active_out "\" ]; then mv \"" active_out "\" \"" backup_file "\"; touch \"" active_out "\"; fi")

            # Update penanda tanggal sekarang
            current_date = log_date
        }

        # Ekstrak thread id WebLogic
        match(raw_line, /\[\[(.*?)\]\]/, arr_thread)
        thread_id = arr_thread[1]

        # 1. Deteksi "110 - aaawebservice"
        if (index(raw_line, "110 - aaawebservice") > 0) {
            t_110[thread_id] = raw_line
            t_outbound[thread_id] = ""
            t_inbound[thread_id] = ""
        }
        # 2. Deteksi "43 - Outbound"
        else if (index(raw_line, "43 - Outbound") > 0 || index(raw_line, "43 - Outbound message") > 0) {
            if (thread_id in t_110 && t_110[thread_id] != "") {
                t_outbound[thread_id] = raw_line
            }
        }
        # 3. Deteksi "43 - Inbound"
        else if (index(raw_line, "43 - Inbound") > 0 || index(raw_line, "43 - Inbound message") > 0) {
            if (thread_id in t_outbound && t_outbound[thread_id] != "") {
                t_inbound[thread_id] = raw_line
                active_inbound_thread = thread_id
            }
        }
    } else {
        # Sambung baris lanjutan XML multiline Inbound
        if (active_inbound_thread != "" && (active_inbound_thread in t_inbound)) {
            clean_chunk = raw_line
            sub(/^[ \t]+/, "", clean_chunk)
            sub(/[ \t]+$/, "", clean_chunk)
            if (clean_chunk != "") {
                t_inbound[active_inbound_thread] = t_inbound[active_inbound_thread] " " clean_chunk
            }
        }
    }

    # Tulis jika 1 set transaksi thread sudah komplit
    for (tid in t_110) {
        if (tid != active_inbound_thread && t_110[tid] != "" && t_outbound[tid] != "" && t_inbound[tid] != "") {
            print t_110[tid] >> active_out
            print t_outbound[tid] >> active_out
            print t_inbound[tid] >> active_out
            fflush(active_out)

            delete t_110[tid]
            delete t_outbound[tid]
            delete t_inbound[tid]
        }
    }
}
'
