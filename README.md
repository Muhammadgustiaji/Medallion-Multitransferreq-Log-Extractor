# Medallion MultiTransferReq Log Extractor

Utilitas pemantauan log berbasis Bash dan GNU AWK untuk mengumpulkan rangkaian request/response dari `medallionConnectorJaxws.log`. Proyek mencakup extractor, contoh service systemd, dan konfigurasi Logstash untuk parsing lanjutan melalui Redis.

Target awal skrip adalah Linux/RHEL 7. Konfigurasi dalam repository memakai path, akun service, dan alamat koneksi generik; sesuaikan melalui konfigurasi lokal sebelum deployment. Pengujian pada lingkungan produksi tetap diperlukan.

## Isi repository

| File | Fungsi |
| --- | --- |
| `extract_medallion_multitransferreq_log.sh` | Mengikuti log sumber, mengorelasikan event per thread, meratakan XML inbound, dan merotasi log hasil. |
| `medallion-multitransferreq.service` | Menjalankan extractor sebagai service systemd dengan restart otomatis. |
| `log-medallion-multitransferreq.conf` | Membaca event JSON dari Redis, mengekstrak field dengan Grok, dan menampilkan hasil ke stdout Logstash. |
| `.env.example` | Contoh konfigurasi path extractor dan koneksi Redis tanpa detail lingkungan internal. |
| `.gitignore` | Mengecualikan konfigurasi lokal, log, data runtime, dan beberapa jenis file kredensial. |
| `.gitattributes` | Menjaga line ending LF untuk file yang digunakan di Linux. |

## Alur kerja

```text
Log aplikasi -> tail -n 0 -F -> AWK -> log aktif + arsip per tanggal

Log hasil -> [pengirim log eksternal] -> Redis list -> Logstash -> stdout
```

Pengirim log ke Redis tidak disertakan. Extractor dan pipeline Logstash merupakan dua komponen terpisah; menjalankan extractor saja tidak mengirim data ke Redis.

### Ekstraksi dan korelasi

1. `tail -n 0 -F` mengikuti baris baru pada file sumber dan mengikuti kembali file berdasarkan nama saat rotasi sumber. Isi yang sudah ada saat startup tidak dibaca ulang.
2. AWK mengenali awal event dari timestamp `YYYY-MM-DD HH:MM:SS,mmm` yang diikuti `[[`.
3. Isi di dalam pasangan `[[...]]` menjadi kunci korelasi thread WebLogic.
4. Event `110 - aaawebservice` memulai rangkaian untuk thread tersebut sekaligus mengosongkan state outbound/inbound sebelumnya.
5. Event `43 - Outbound` disimpan jika thread sudah memiliki event awal. Event `43 - Inbound` disimpan jika outbound sudah tersedia.
6. Baris lanjutan tanpa timestamp setelah inbound digabungkan menjadi satu baris, dengan spasi di awal/akhir setiap potongan dibuang.
7. Setelah event bertimestamp berikutnya menutup inbound aktif, rangkaian lengkap ditulis sebagai tiga baris: event awal, outbound, dan inbound. `fflush()` dipanggil setelah penulisan agar buffer output AWK dikosongkan.

Nama proyek merujuk pada `multiTransferReq`, tetapi implementasi saat ini **belum memeriksa nilai command**. Rangkaian lain dengan marker yang sama juga dapat masuk ke hasil.

### Output dan rotasi

| Output | Nama file |
| --- | --- |
| Log aktif | `medallion_multitransferreq.log` |
| Arsip | `medallion_multitransferreq_DDMMYYYY.log` |

Direktori output dibuat otomatis. Tanggal awal diambil dari tanggal sistem; perubahan tanggal pada setiap event bertimestamp memicu pemindahan log aktif yang tidak kosong ke arsip bertanggal sebelumnya yang tersimpan di state. File aktif kosong dibuat kembali, lalu penanda tanggal diperbarui.

Rotasi mengikuti tanggal event, bukan timer tengah malam. Event lama atau tidak berurutan juga dapat memicu rotasi. File arsip dengan nama yang sama dapat ditimpa oleh `mv`. Tidak ada kompresi, retensi otomatis, atau penguncian untuk beberapa instance.

### Parsing Logstash

Input Redis memakai `data_type => "list"`, key `log-medallion-multitransferreq`, dan codec JSON. Pengirim eksternal perlu menyediakan objek JSON dengan field `message` berisi satu baris log hasil extractor.

Grok mengenali metadata timestamp, status/nomor thread, queue, process ID, level, logger, dan kode baris. Cabang pola menangani:

- Request `aaawebservice`: informasi channel, reference, user/supervisor, system, rekening, jenis transaksi, nominal, narasi, dan journal; termasuk varian inquiry.
- Outbound: detail debit/kredit, nominal, net total, atau rekening inquiry dari XML.
- Inbound: hasil transaksi, journal, tanggal/jam response, rekening/nama/cabang, atau hasil inquiry berupa nama nasabah, saldo, status, dan jenis rekening.
- SOAP fault: kode, pesan, dan deskripsi error opsional.

Pola bergantung pada nama field, susunan atribut, dan urutan elemen XML yang tertulis di konfigurasi. Kegagalan pencocokan umumnya menghasilkan tag `_grokparsefailure`. Field timestamp hasil parsing belum dikonversi menjadi `@timestamp` event karena tidak ada filter `date`.

Blok `mutate` menghapus koma dari `settlement_unit` dan mengonversi `line` serta `settlement_unit` menjadi integer bila field itu tersedia. Pola Grok yang disertakan tidak menghasilkan kedua field tersebut; sebagian besar field angka lain tetap berupa string. Output hanya `stdout` dengan codec `rubydebug`; output Elasticsearch atau penyimpanan lain belum disediakan.

## Kebutuhan

- Linux dengan Bash, GNU AWK (`awk` harus mengarah ke GNU AWK), GNU `tail`, dan GNU `date` yang mendukung `-d`.
- Utilitas `mkdir`, `mv`, dan `touch`, serta izin baca log sumber dan tulis direktori output.
- systemd jika menggunakan file service.
- Untuk pipeline opsional: Logstash beserta plugin Redis input, Grok, Mutate, dan Rubydebug, serta Redis yang dapat diakses. Versi Logstash perlu mendukung substitusi environment `${VAR:default}` dan perlu diuji di lingkungan tujuan.

## Menjalankan extractor secara manual

Contoh berikut memakai lokasi generik. Jalankan dari direktori proyek pada Linux dan arahkan `INPUT_DIR` ke direktori log uji terlebih dahulu.

```bash
cp .env.example .env
# Edit INPUT_DIR dan OUTPUT_DIR di .env sesuai lingkungan lokal.
set -a
. ./.env
set +a
bash -n extract_medallion_multitransferreq_log.sh
bash extract_medallion_multitransferreq_log.sh
```

Skrip tidak memuat `.env` secara otomatis. Nilai harus diekspor sebelum menjalankannya. Log sumber selalu bernama `medallionConnectorJaxws.log`; nama log aktif dan arsip juga ditetapkan di skrip.

| Variabel | Default contoh | Digunakan oleh |
| --- | --- | --- |
| `INPUT_DIR` | `/var/log/example-app/server` | Extractor |
| `OUTPUT_DIR` | `/var/log/log-extractor/multitransferreq` | Extractor |
| `REDIS_HOST` | `127.0.0.1` | Logstash |
| `REDIS_PORT` | `6379` | Logstash |

Gunakan path absolut sederhana dari konfigurasi tepercaya. Path output diteruskan ke perintah shell di AWK saat rotasi; karakter kutip, backtick, `$`, dan karakter shell khusus lainnya belum di-escape untuk penggunaan tersebut.

## Instalasi sebagai service systemd

Contoh berikut menggunakan akun service generik `logextractor`. Sesuaikan jika akun tersebut sudah tersedia atau kebijakan server menggunakan akun lain.

```bash
sudo groupadd --system logextractor
sudo useradd --system --gid logextractor --no-create-home --shell /sbin/nologin logextractor
sudo install -d -m 0755 /opt/log-extractor
sudo install -m 0644 extract_medallion_multitransferreq_log.sh /opt/log-extractor/
sudo install -d -o logextractor -g logextractor -m 0750 /var/log/log-extractor/multitransferreq
sudo install -m 0644 medallion-multitransferreq.service /etc/systemd/system/
sudo install -m 0600 .env.example /etc/default/medallion-multitransferreq
# Edit file environment tersebut dan berikan akun service izin baca log sumber
# serta izin traversal seluruh direktori induknya sesuai kebijakan server.
sudo systemctl daemon-reload
sudo systemctl enable --now medallion-multitransferreq.service
```

`EnvironmentFile` bersifat opsional; bila tidak ada, default skrip digunakan. `User`/`Group` adalah akun OS lokal dan harus disesuaikan langsung di unit atau melalui drop-in systemd. `ExecStart` sudah mengarah ke nama skrip yang ada di repository. Service memakai `Restart=always` dengan jeda lima detik.

```bash
sudo systemctl status medallion-multitransferreq.service
sudo journalctl -u medallion-multitransferreq.service -f
tail -f /var/log/log-extractor/multitransferreq/medallion_multitransferreq.log
sudo systemctl stop medallion-multitransferreq.service
```

Unit menjalankan pipeline Bash tanpa `pipefail` atau pengawasan terpisah pada `tail`. Restart otomatis bergantung pada proses utama yang berhenti, sehingga belum menjamin pemulihan setiap kegagalan salah satu komponen pipeline.

## Menjalankan Logstash (opsional)

Atur `REDIS_HOST` dan `REDIS_PORT` pada environment proses/service **Logstash**, lalu validasi konfigurasi sebelum menjalankannya. Memuat environment extractor di systemd tidak otomatis memasok environment ke service Logstash.

```bash
export REDIS_HOST=127.0.0.1
export REDIS_PORT=6379
/usr/share/logstash/bin/logstash --config.test_and_exit -f ./log-medallion-multitransferreq.conf
/usr/share/logstash/bin/logstash -f ./log-medallion-multitransferreq.conf
```

Path executable di atas adalah contoh instalasi Linux. Input Redis yang disertakan belum mengatur password maupun TLS; sesuaikan konfigurasi deployment lokal bila diperlukan. Tidak ada kredensial Redis di repository.

## Batasan operasional

- Hanya inbound multiline yang digabungkan. Outbound multiline belum ditangani.
- Inbound terakhir menunggu event bertimestamp berikutnya sebelum ditulis. Tidak ada flush transaksi pada shutdown/EOF, timeout transaksi, maupun persistensi state; restart dapat kehilangan transaksi yang belum selesai.
- Buffer pada pipeline `tail | awk` dapat menambah jeda; `fflush()` hanya mengosongkan buffer output AWK, bukan buffer input.
- Korelasi hanya berdasarkan thread, tanpa transaction ID. Pemakaian ulang thread atau event yang terlewat dapat mengganti/mengacaukan state. Transaksi tidak lengkap dapat tetap tersimpan dalam memori.
- Rotasi berlangsung sebelum pemeriksaan kelengkapan transaksi pada event baru. Transaksi yang melintasi pergantian tanggal dapat masuk file aktif setelah rotasi.
- Timestamp hanya dicocokkan dengan pola dasar, tanpa validasi kalender menyeluruh. Perintah file saat rotasi belum diperiksa hasilnya, dan stderr `tail` dibuang.
- Tidak tersedia endpoint, antarmuka web, database, pengirim Redis, atau suite pengujian otomatis dalam proyek ini.

## Masking dan persiapan GitHub

Nama/ID pegawai dan keterangan divisi pada header telah diganti dengan identitas maintainer generik. Path deployment serta akun OS telah diganti contoh generik; path input/output dapat dioverride lewat environment. Redis menggunakan default loopback dan port contoh yang valid. Isi konfigurasi lokal `.env` tidak perlu dimasukkan ke Git.

**Masking ini berlaku untuk konfigurasi repository.** Extractor tetap menulis isi log transaksi asli, dan Logstash dapat menampilkan nomor rekening, nama nasabah, ID pengguna, saldo, serta field sensitif lain ke stdout. Nama field seperti `user_id` dan `client_user_id` dipertahankan karena merupakan bagian dari skema parsing. Jangan memasukkan log nyata atau konfigurasi internal ke repository; gunakan data sintetis untuk contoh.

Untuk publikasi dari folder ini, setelah membuat repository GitHub kosong dan mengganti URL contoh:

```bash
git init -b main
git add .
git diff --cached --check
git diff --cached
git commit -m "Document log extractor and sanitize deployment configuration"
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
```

URL `OWNER/REPOSITORY` adalah placeholder. Tinjau file yang masuk staging sebelum commit; `.gitignore` tidak memindai rahasia dan tidak menghapus file yang sudah terlacak Git.
