# Windows driver REA findings — OV01A1S (Avell B.ON / Intel IPU6 TGL)

Reverse engineering of the OEM Windows sensor driver with REA + Ghidra 12.1.4.
This is analysis evidence only; no Windows binary is redistributed here.

## Artifacts

Source: DriverStore export shared at
`smb://cachyos.local/data/downloads/automatizados/automatizados/Drivers`
(local copies under `windows-driverstore/`).

| Artifact | Details |
| --- | --- |
| `ov01a1s.sys` | PE32+ x86-64, 178008 bytes, SHA-256 `c610af4885647c526e08c2344dc775f755e14be02924a0998e8b8a82aadd3abd` |
| PDB path | `C:\w\s\repo\w\camerasw\Source\Camera\Platform\TGL\x64\Release\ov01a1s.pdb` (RSDS GUID `12e197adc78246408e5e7f09538224b3`, age 1) |
| INF | `ov01a1s.inf` — `ACPI\OVTI01AF`, DriverVer 09/16/2020, 60.19041.1.3035, depends `SpbCx,inteli2c` |
| Tuning | `OV01A1S_YHRN_TGL.aiqb`, `OV01A1S_YHRN180_TGL.aiqb` (588896 B each), `.cpf` |
| Graph settings | `graph_settings_ov01a1s_YHRN_TGL.xml`, `..._YHRN180_TGL.xml` (238906 B each) |
| Intel stack | `iacamera64.sys` (11 MB), `iaisp64.sys`, `evcp.dll`, `libia_cp64.dll`, `pvl64.dll`, `graph_descriptor.xml` |

## REA setup used

- Ghidra 12.1.4 + Temurin JDK 21 in `~/opt` (REA requires exactly 12.1.4 / Java 21).
- `rea doctor` reports provider `ghidra` available, `providerVersion: 12.1.4`.
- Analysis via CLI with `--snapshot windows-driverstore/.rea-snapshot-ov01a1s`.

Evidence IDs:

- `ev_476bb37be960ec31c36bed3c3ad0a1f4198b92eb994c387a2f0b6590bf2ec598` — `inspect_pe_resources`
- `ev_ac8d896b3332189f21e65eb7b5c32ab3110bac1b6ea7b6c3df1ce023ef119be2` — `binary_overview` (411 procedures, 591 strings, 10 segments)
- `ev_b22fda530197c02d0206c3a02c42e769a5b539e58b4b6cdb1a61fb3d98946b5f` — `search_strings`
- `ev_06bec8022ca62fa05d94e225349df4d507c42e97a35149662108a54557e129a3` — `analyze_function` (`FUN_140009660`)
- `ev_387f213931a0fb46ca55735ced6c4d3d828d6e28065bc1cd5113c2b23dc0dcf3` — `analyze_function` (`FUN_140014314`)

## Register tables recovered (`.rdata`)

Record format (16 bytes): `{u32 len = 1; u32 addr; u32 val; u32 delay}`, list
terminated by `addr = 0xffff`.

| Table VA | File offset | Entries | Role |
| --- | --- | --- | --- |
| `0x14001f5e0` | `0x1dbe0` | 1 | software reset (`0x0103 = 0x01`) |
| `0x14001f620` | `0x1dc20` | 145 | mode 1296x800 @30fps, HTS 0x05d0, 800 Mbps |
| `0x14001ff40` | `0x1e540` | 145 | mode 1296x800 @60fps, HTS 0x02e8, 720 Mbps |
| `0x140020860` | `0x1ee60` | 145 | mode 1292x732 @30fps (crop 0x3811=3, 0x3813=0x28) |
| `0x140021180` | `0x1f780` | 145 | mode 1292x732 @60fps |

Full dumps: `diagnostics/rea/windows-ov01a1s-regtables.txt` (and `.json`).

Small control tables used by the init path (16-byte records, `addr=0xffff` end):

- `0x14001f5a0`: `{0x0100, 0x00}`
- `0x14001f5c0` (approx.): `{0x0100, 0x01}`
- `0x14001f5e0`: `{0x0103, 0x01}`

## Mode descriptors (`.data`)

Pointer array at `0x1400249a0` → descriptors at `0x140024aa0`, `0x140024c50`,
`0x140024e00`, `0x140024fb0` (stride `0x1b0`, sub-modes stride `0x90`).

Observed fields (u32 unless noted):

- width `0x0510` = 1296, height `0x0320` = 800
- fps `0x1e` = 30 / `0x3c` = 60
- pixel rate `0x2faf0800` = 800,000,000 / `0x2aea5400` = 720,000,000
- pointer to the matching register table (e.g. `0x140024b58` → `0x14001f620`)

Init function `FUN_140009660`:

1. writes the reset table `0x14001f5e0` and the `0x0100` control tables;
2. selects the mode table from the descriptor array (`param_2`, `param_3`);
3. programs output size/HTS/VTS from descriptor fields (writes `0x380e` via
   `FUN_1400042d8`);
4. if the module name is `YHRN180` (`_stricmp((char *)(param_1 + 0x1344), "YHRN180")`),
   reads `0x3820`, XORs with `0x18`, writes it back — the rotated variant flip.

I2C access is through `FUN_14000c6d0` (generic transfer); `FUN_140014314` is the
"read register" wrapper that logs `Failed to read register 0x%x`.

## Differences vs the Linux driver

Linux `sensor_1288x800_setting[]` (`drivers/media/i2c/ov01a1s.c`) has 132 entries;
the Windows 30fps table has 145 (same register set, repeated writes). Value
differences:

| Register | Linux | Windows (0x14001f620) | Notes |
| --- | --- | --- | --- |
| `0x3809` | `0x08` (width LSB → 1288) | `0x00` | runtime override to 1296 |
| `0x380c`/`0x380d` | `0x05d0` (HTS 1488) | `0x05d0` (30fps) / `0x02e8` (60fps) | Windows has 60fps mode |
| `0x3811` | `0x08` | `0x09` | crop |
| `0x3813` | `0x09` | `0x08` | crop |
| `0x3820` | `0x88` | `0xa8` | flip/mirror; `^0x18` for YHRN180 |

## Tuning blobs (AIQB) — Windows vs Intel Linux HAL

Both are CPFF containers with `LCMCP` / `DFLT` / `AIQB` sections.

| | Windows | Linux `ipu6-camera-hal` |
| --- | --- | --- |
| File | `OV01A1S_YHRN_TGL.aiqb` (588896 B) | `ov01a1s.aiqb` (623756 B) |
| IQStudio | 20.37.1.0, "0915 DPC Release" (2020-09-15) | 20.44.4.0, "WW51.3-DPC Strong-IRMA Strong" (2020-12-16) |
| Graph settings | 238906 B, `IPU6_20200802.0.1.0.245...` | 17685 B (gcss) + `sensors/ov01a1s-uf.xml` |

The Linux HAL tuning is newer and explicitly labelled `Strong-IRMA` (IR
mitigation), so the Windows AIQB is not automatically the better option. The
Linux reference files were fetched to
`windows-driverstore/linux-hal-reference/` for comparison.

## Practical implications

1. The Linux sensor driver already covers the same register space; the Windows
   evidence adds the 60fps timing (HTS `0x02e8`, 720 Mbps), the 1292x732 crop
   profile, and the `YHRN180` flip handling (`0x3820 ^= 0x18`).
2. Debian's libcamera 0.7.x ships no IPU6 IPA (`ipu3`/`simple`/`vimc` only), so
   the hardware-ISP path needs Intel's `ipu6-camera-hal` + `icamerasrc` stack
   (not packaged in Debian) or a libcamera build with the IPU6 IPA.
3. Current regression: the running kernel's stock `ipu-bridge.ko` lacks
   `OVTI01AF`; restore with `tools/rebuild_ipu_bridge_ovti01af.sh`.
