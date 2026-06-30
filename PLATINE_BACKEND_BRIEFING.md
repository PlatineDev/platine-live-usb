# Platine.dev — Briefing Técnico Completo para Backend + Comunidad

## Contexto del Proyecto

**Platine Live USB** es una ISO bootable (Alpine Linux) que un técnico flashea en un USB.
Lo enchufas en cualquier PC, booteas, conectas el celular por cable (USB tethering),
y en ~20 segundos tienes el diagnóstico completo subido a platine.dev visible en el celular.

El scanner (`platine-scan.sh` v2.1.0) corre 13 módulos en paralelo y genera un JSON estructurado
que se sube vía REST API. El backend necesita recibirlo, almacenarlo, mostrarlo bien, y soportar
una comunidad de técnicos que comparten reparaciones.

---

## Repo del Scanner

`github.com/platinedev/platine-live-usb` — rama `claude/platine-live-usb-scanner-sdugcg`

---

## JSON Completo que Genera el Scanner

Este es el schema exacto. Todos los campos pueden ser `null` si el hardware no está disponible.

```json
{
  "platine_version": "2.1.0",
  "scan_id": "3A7F9C12",
  "scanned_at": "2026-06-30T14:22:11",
  "scan_duration_s": 18,
  "health_score": 67,
  "health_label": "FAIR",
  "issues_count": 3,
  "vendor": "Dell",
  "model": "XPS 15 9520",
  "form_factor": "laptop",

  "machine": {
    "manufacturer": "Dell Inc.",
    "model": "XPS 15 9520",
    "serial": "ABCD1234",
    "uuid": "4C4C4544-...",
    "chassis_type": "Notebook",
    "bios_version": "1.18.0",
    "bios_date": "05/10/2022",
    "bios_age_years": 4
  },

  "cpu": {
    "model": "12th Gen Intel(R) Core(TM) i7-12700H",
    "vendor": "GenuineIntel",
    "architecture": "x86_64",
    "cores": 14,
    "threads": 20,
    "sockets": 1,
    "current_mhz": 1200,
    "base_mhz": 2300,
    "max_mhz": 4700,
    "temp_c": 89.0,
    "per_core_temps_c": [88.0, 91.0, 87.0, 89.0, 90.0, 88.0, 87.0, 89.0],
    "throttle_active": true,
    "throttle_reason": "thermal",
    "throttle_count": 1247,
    "cache": {
      "l1d": "48K",
      "l1i": "32K",
      "l2": "1.25M",
      "l3": "24M"
    },
    "flags": "fpu,vme,de,pse,tsc,msr,pae,mce,vmx,smx,est,tm2,ssse3,..."
  },

  "ram": {
    "total_gb": 16.0,
    "available_gb": 10.2,
    "speed_mhz": 4800,
    "configured_mhz": 2133,
    "xmp_available": true,
    "xmp_enabled": false,
    "is_lpddr": false,
    "slots": [
      {
        "locator": "ChannelA-DIMM0",
        "size": "8 GB",
        "type": "DDR5",
        "speed": 4800,
        "manufacturer": "SK Hynix",
        "part_number": "HMCG78AEBSA..."
      }
    ]
  },

  "storage": {
    "drives": [
      {
        "device": "/dev/nvme0n1",
        "type": "NVMe",
        "model": "Samsung SSD 980 PRO 512GB",
        "serial": "S5GXNF0R...",
        "size_gb": 476,
        "read_speed_mbps": 3210,
        "smart_health": "PASSED",
        "temp_c": 38,
        "power_hours": 4821,
        "reallocated_sectors": 0,
        "pending_sectors": 0,
        "uncorrectable": 0,
        "nvme_percentage_used": 12,
        "nvme_available_spare": 100,
        "nvme_unsafe_shutdowns": 47,
        "nvme_power_cycles": 1203,
        "smart_attrs": []
      },
      {
        "device": "/dev/sda",
        "type": "HDD",
        "model": "WDC WD10EZEX-08WN4A0",
        "serial": "WD-...",
        "size_gb": 931,
        "read_speed_mbps": 117,
        "smart_health": "PASSED",
        "temp_c": 42,
        "power_hours": 18234,
        "reallocated_sectors": 47,
        "pending_sectors": 3,
        "uncorrectable": 0,
        "nvme_percentage_used": null,
        "nvme_available_spare": null,
        "nvme_unsafe_shutdowns": null,
        "nvme_power_cycles": null,
        "smart_attrs": [
          { "id": 1,   "name": "Raw_Read_Error_Rate", "value": 112, "worst": 99, "thresh": 6, "type": "Pre-fail", "raw": 0 },
          { "id": 5,   "name": "Reallocated_Sector_Ct", "value": 47, "worst": 47, "thresh": 36, "type": "Pre-fail", "raw": 47 },
          { "id": 9,   "name": "Power_On_Hours", "value": 78, "worst": 78, "thresh": 0, "type": "Old_age", "raw": 18234 },
          { "id": 190, "name": "Airflow_Temperature_Cel", "value": 56, "worst": 45, "thresh": 45, "type": "Old_age", "raw": 42 }
        ]
      }
    ]
  },

  "battery": {
    "batteries": [
      {
        "name": "BAT0",
        "status": "Discharging",
        "technology": "Li-ion",
        "manufacturer": "SMP",
        "charge_pct": 73,
        "health_pct": 84,
        "design_mwh": 86000,
        "full_mwh": 72240,
        "voltage_v": 11.880,
        "cycle_count": 312,
        "swelling_risk": false
      }
    ]
  },

  "gpu": {
    "gpus": [
      {
        "slot": "00:02.0",
        "model": "Intel Iris Xe Graphics",
        "driver": "i915",
        "revision": "0x0c",
        "firmware": "",
        "vram_mb": null,
        "temp_c": null
      },
      {
        "slot": "01:00.0",
        "model": "NVIDIA GeForce RTX 3050 Ti",
        "driver": "nouveau",
        "revision": "0xa1",
        "firmware": "",
        "vram_mb": 4096,
        "temp_c": 52
      }
    ]
  },

  "network": {
    "interfaces": [
      {
        "interface": "usb0",
        "type": "USB-Ethernet",
        "mac": "72:1a:3b:...",
        "status": "up",
        "carrier": 1,
        "speed_mbps": null,
        "duplex": null,
        "driver": "rndis_host",
        "wifi_ssid": null,
        "wifi_channel": null,
        "wifi_freq_ghz": null,
        "wifi_signal_dbm": null
      },
      {
        "interface": "wlp2s0",
        "type": "WiFi",
        "mac": "a4:c3:f0:...",
        "status": "up",
        "carrier": 1,
        "speed_mbps": null,
        "duplex": null,
        "driver": "iwlwifi",
        "wifi_ssid": "CasaDePepe",
        "wifi_channel": 36,
        "wifi_freq_ghz": "5.180 GHz",
        "wifi_signal_dbm": -58
      }
    ]
  },

  "thermals": {
    "sensors": [
      { "hwmon": "coretemp", "label": "Package id 0", "temp_c": 89.0, "crit_c": 100.0 },
      { "hwmon": "coretemp", "label": "Core 0", "temp_c": 88.0, "crit_c": 100.0 },
      { "hwmon": "amdgpu",   "label": "edge",    "temp_c": 52.0, "crit_c": null }
    ],
    "fans": [
      { "hwmon": "dell_smm", "label": "CPU Fan",  "rpm": 0,    "min_rpm": 800 },
      { "hwmon": "dell_smm", "label": "GPU Fan",  "rpm": 2340, "min_rpm": 600 }
    ],
    "fan_count": 2,
    "fans_stopped": 1
  },

  "audio": {
    "cards": [
      { "card": "card0", "name": "PCH", "codec": "Realtek ALC289" }
    ]
  },

  "usb": {
    "devices": [
      { "vid": "0bda", "pid": "8153", "name": "Realtek USB 10/100/1000 LAN" },
      { "vid": "0781", "pid": "5581", "name": "SanDisk Ultra" }
    ]
  },

  "os": {
    "name": "Alpine Linux v3.20",
    "kernel": "6.6.21-0-lts",
    "uptime_s": 43,
    "bios_version": "1.18.0",
    "bios_date": "05/10/2022"
  },

  "security": {
    "secure_boot": "disabled",
    "tpm": "TPM 2.x",
    "iommu": true
  },

  "android": {
    "detected": true,
    "device_serial": "R5CT710XXXX",
    "brand": "samsung",
    "model": "SM-A546B",
    "android_version": "14",
    "security_patch": "2024-01-01",
    "hardware": "s5e8835",
    "cpu_abi": "arm64-v8a",
    "battery": {
      "level_pct": 78,
      "health": "good",
      "temp_c": 28.5,
      "voltage_v": 4.123
    },
    "ram": {
      "total_gb": 6.0,
      "available_gb": 2.3
    },
    "storage": {
      "total_gb": 128.0,
      "available_gb": 47.2
    }
  },

  "netspeed": {
    "ping_ms": 18.4,
    "packet_loss_pct": 0,
    "download_mbps": 94.2,
    "upload_mbps": 31.7
  },

  "problems": [
    {
      "severity": "critical",
      "component": "thermals",
      "title": "Fan not spinning — dell_smm/CPU Fan",
      "cause": "Fan RPM reads 0 while system is running",
      "action": "Check fan connector, clear obstructions, or replace fan."
    },
    {
      "severity": "critical",
      "component": "storage",
      "title": "Drive failure imminent — sda",
      "cause": "47 reallocated sector(s)",
      "action": "Backup all data immediately. Replace drive."
    },
    {
      "severity": "warning",
      "component": "ram",
      "title": "XMP/EXPO profile not enabled",
      "cause": "RAM rated at 4800 MT/s but running at 2133 MT/s",
      "action": "Enable XMP/EXPO in BIOS for full performance."
    },
    {
      "severity": "warning",
      "component": "machine",
      "title": "BIOS update recommended (4 years old)",
      "cause": "BIOS 1.18.0 dated 05/10/2022",
      "action": "Check manufacturer website for BIOS updates."
    }
  ]
}
```

---

## API REST que el Scanner Usa

El scanner hace exactamente estas dos llamadas HTTP:

### 1. POST /api/live/start
Se llama una vez al terminar el scan. Body: el JSON completo de arriba.

```
POST https://platine.dev/api/live/start
Content-Type: application/json

{ ...todo el JSON del scan... }
```

**Respuesta esperada:**
```json
{
  "session_id": "sess_abc123",
  "live_url": "https://platine.dev/scan/sess_abc123",
  "expires_at": "2026-06-30T16:22:11Z"
}
```

### 2. POST /api/live/update
Se llama cada 5 segundos mientras el técnico tiene el USB puesto (live monitoring loop).

```
POST https://platine.dev/api/live/update
Content-Type: application/json

{
  "session_id": "sess_abc123",
  "cpu_load": 23,
  "cpu_temp_c": 72.5,
  "ram_free_gb": 8.4,
  "updated_at": "2026-06-30T14:22:16"
}
```

**Respuesta:** cualquier 2xx es suficiente. El scanner no lee el body de respuesta.

---

## Arquitectura Backend Recomendada

### Stack sugerido
- **Framework**: Next.js 14+ con App Router (frontend + API routes en uno)
- **DB**: PostgreSQL con Prisma ORM
- **Cache/Realtime**: Redis + Pusher o Ably para live updates
- **Storage**: Cloudflare R2 o S3 para videos de la comunidad
- **Auth**: Clerk o NextAuth.js
- **Deploy**: Vercel + Railway (DB) o Render

### Tablas principales (Prisma schema)

```prisma
model Scan {
  id            String   @id @default(cuid())
  session_id    String   @unique
  scan_id       String                        // ej: "3A7F9C12"
  scanned_at    DateTime
  scan_duration_s Int?
  health_score  Int?
  health_label  String?
  vendor        String?
  model         String?
  form_factor   String?                       // laptop | desktop | aio | unknown
  raw_json      Json                          // todo el JSON del scanner guardado tal cual
  live_url      String?
  expires_at    DateTime?
  created_at    DateTime @default(now())
  updated_at    DateTime @updatedAt

  live_updates  LiveUpdate[]
  problems      Problem[]
  repairs       Repair[]    // reparaciones vinculadas a este modelo
}

model LiveUpdate {
  id          String   @id @default(cuid())
  scan_id     String
  scan        Scan     @relation(fields: [scan_id], references: [id])
  cpu_load    Float?
  cpu_temp_c  Float?
  ram_free_gb Float?
  recorded_at DateTime @default(now())
}

model Problem {
  id          String   @id @default(cuid())
  scan_id     String
  scan        Scan     @relation(fields: [scan_id], references: [id])
  severity    String   // critical | warning | info
  component   String   // cpu | ram | storage | battery | thermals | ...
  title       String
  cause       String
  action      String
  created_at  DateTime @default(now())
}

model Technician {
  id          String   @id @default(cuid())
  clerk_id    String   @unique
  username    String   @unique
  name        String
  bio         String?
  location    String?
  avatar_url  String?
  verified    Boolean  @default(false)
  created_at  DateTime @default(now())

  repairs     Repair[]
  comments    Comment[]
  votes       Vote[]
}

model Repair {
  id            String      @id @default(cuid())
  technician_id String
  technician    Technician  @relation(fields: [technician_id], references: [id])
  scan_id       String?     // scan vinculado (opcional)
  scan          Scan?       @relation(fields: [scan_id], references: [id])

  title         String
  description   String
  device_vendor String?     // "Dell"
  device_model  String?     // "XPS 15 9520"
  components    String[]    // ["cpu", "thermals", "battery"]
  difficulty    Int         // 1-5
  time_minutes  Int?
  cost_usd      Float?

  videos        Video[]
  comments      Comment[]
  votes         Vote[]
  tags          Tag[]

  views         Int      @default(0)
  published     Boolean  @default(false)
  created_at    DateTime @default(now())
  updated_at    DateTime @updatedAt
}

model Video {
  id          String   @id @default(cuid())
  repair_id   String
  repair      Repair   @relation(fields: [repair_id], references: [id])
  url         String   // R2/S3 URL
  thumbnail   String?
  duration_s  Int?
  order       Int      @default(0)
  created_at  DateTime @default(now())
}

model Comment {
  id            String      @id @default(cuid())
  repair_id     String?
  repair        Repair?     @relation(fields: [repair_id], references: [id])
  technician_id String
  technician    Technician  @relation(fields: [technician_id], references: [id])
  parent_id     String?     // para respuestas anidadas
  parent        Comment?    @relation("replies", fields: [parent_id], references: [id])
  replies       Comment[]   @relation("replies")
  body          String
  created_at    DateTime    @default(now())
}

model Vote {
  id            String     @id @default(cuid())
  repair_id     String
  repair        Repair     @relation(fields: [repair_id], references: [id])
  technician_id String
  technician    Technician @relation(fields: [technician_id], references: [id])
  value         Int        // 1 o -1

  @@unique([repair_id, technician_id])
}

model Tag {
  id      String   @id @default(cuid())
  name    String   @unique
  repairs Repair[]
}
```

---

## Endpoints de API Necesarios

### Scan (los que usa el scanner)
```
POST /api/live/start          → recibe JSON completo, devuelve session_id + live_url
POST /api/live/update         → recibe live updates cada 5s
```

### Scan (para el frontend de platine.dev)
```
GET  /api/scan/:session_id    → devuelve el scan completo (para mostrar en pantalla)
GET  /api/scan/:session_id/live → SSE/WebSocket para live updates en tiempo real
GET  /api/scan/:session_id/problems → lista de problemas filtrable
```

### Comunidad — Reparaciones
```
GET  /api/repairs             → lista paginada, filtrable por component/model/difficulty
GET  /api/repairs/:id         → reparación completa con videos y comentarios
POST /api/repairs             → crear nueva reparación (auth requerida)
PUT  /api/repairs/:id         → editar (solo autor o admin)
DEL  /api/repairs/:id         → eliminar

POST /api/repairs/:id/videos  → subir video (multipart/form-data)
POST /api/repairs/:id/vote    → votar +1/-1
GET  /api/repairs/:id/comments
POST /api/repairs/:id/comments

GET  /api/repairs/search?q=XPS+fan+replacement&component=thermals&model=XPS+15
```

### Técnicos
```
GET  /api/technicians/:username     → perfil público
GET  /api/technicians/:username/repairs → sus reparaciones
POST /api/technicians/me            → actualizar perfil propio
```

### Búsqueda inteligente
```
GET /api/search/model?q=Dell+XPS+15+9520 → reparaciones para ese modelo exacto
GET /api/search/problem?component=thermals&title=fan+not+spinning → reparaciones para ese problema
```

---

## Funcionalidades del Frontend (platine.dev)

### Página del Scan — `/scan/:session_id`

El técnico escanea el QR con el celular y ve:

**Header:**
- Modelo del equipo: "Dell XPS 15 9520"
- Health score: gran círculo con 67/100 en rojo
- Fecha y duración del scan

**Sección de Problemas (los críticos primero):**
```
🔴 CPU Fan Not Spinning
   "Fan RPM reads 0 while system is running"
   → Check fan connector, clear obstructions, or replace fan.
   [Ver reparaciones para este problema] ← link a comunidad

🔴 Drive Failure Imminent — /dev/sda
   "47 reallocated sectors"
   → Backup all data immediately. Replace drive.

🟡 XMP Profile Not Enabled
   "RAM running at 2133 MT/s, rated 4800 MT/s"
   → Enable XMP in BIOS.
```

**Sección Hardware (tabs o acordeón):**
- CPU: modelo, temp, freq, caché, throttling
- RAM: slots, XMP status
- Storage: tabla de discos con SMART, velocidad lectura, salud NVMe
- Batería: salud%, ciclos, swelling
- GPU(s): modelo, VRAM, temp
- Red: interfaces, WiFi SSID/canal/señal, velocidad internet
- Ventiladores: RPM por ventilador
- Seguridad: Secure Boot, TPM, IOMMU
- BIOS: versión, fecha, antigüedad
- Android (si detectó teléfono): marca/modelo/batería/RAM/storage
- Velocidad de red: ↓ MB/s ↑ MB/s latencia

**Live Monitor (mientras el USB está conectado):**
- Gráfica en tiempo real de CPU load + CPU temp (SSE/WebSocket)
- Actualización cada 5 segundos

### Comunidad — `/repairs`

Feed de reparaciones con:
- Filtros: componente afectado, marca/modelo, dificultad, tiempo
- Cards con: thumbnail del video, título, modelo, votos, vistas
- Búsqueda por síntoma ("fan not spinning dell xps")
- Match automático: si el scan detectó "Fan not spinning" → muestra reparaciones para ese problema

### Perfil de Reparación — `/repairs/:id`

- Video embebido (o galería si hay varios)
- Descripción paso a paso
- Herramientas necesarias
- Costo aproximado
- Dificultad (1-5 estrellas)
- Comentarios/respuestas
- Votos
- "¿Este equipo tiene ese problema?" — botón para vincular con tu scan

### Perfil de Técnico — `/tech/:username`

- Bio, localización
- Reparaciones publicadas (ordenadas por votos)
- Badge si está verificado
- Stats: total de reparaciones, votos recibidos, vistas totales

---

## Feature Estrella: Match Automático Scan → Reparación

Cuando se carga un scan con problemas, el backend busca automáticamente:

```
problema.component = "thermals" AND problema.title LIKE "%fan%"
    → busca repairs donde components @> ['thermals'] AND tags incluyen 'fan'

problema.component = "storage" AND reallocated_sectors > 0
    → busca repairs donde components @> ['storage'] AND tags incluyen 'hdd-replacement'

machine.vendor = "Dell" AND machine.model LIKE "XPS 15%"
    → filtra repairs por device_vendor = "Dell" y device_model LIKE "XPS 15%"
```

Resultado: en la página del scan, debajo de cada problema hay un botón
"Ver cómo repararlo (3 guías)" que lleva directo a las reparaciones relevantes.

Esto es lo que hace que la comunidad sea parte del producto, no un extra.

---

## Variables de Entorno Necesarias

```env
DATABASE_URL="postgresql://..."
REDIS_URL="redis://..."
NEXT_PUBLIC_APP_URL="https://platine.dev"
CLERK_SECRET_KEY="..."
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY="..."
R2_ACCOUNT_ID="..."
R2_ACCESS_KEY_ID="..."
R2_SECRET_ACCESS_KEY="..."
R2_BUCKET_NAME="platine-videos"
PUSHER_APP_ID="..."
PUSHER_KEY="..."
PUSHER_SECRET="..."
PUSHER_CLUSTER="..."
```

---

## Reglas de Negocio Importantes

- `session_id` expira a las 2 horas — luego el scan sigue accesible pero en modo solo lectura
- Los live updates solo se aceptan si el `session_id` existe y no ha expirado
- Un scan sin `session_id` no existe — el scanner no puede crear sesiones sin subir el JSON
- Reparaciones son públicas por defecto, pero se pueden hacer privadas
- Videos: máximo 500MB por video, formatos mp4/webm/mov
- Comentarios: solo técnicos autenticados
- Votos: máximo 1 por técnico por reparación (puede cambiar)
- Health score: 100 - (críticos × 20) - (warnings × 7), mínimo 0
  - 90-100 = EXCELLENT
  - 75-89  = GOOD
  - 55-74  = FAIR
  - 30-54  = POOR
  - 0-29   = CRITICAL

---

## Branding — Logo Platine Obligatorio

El logo de Platine 💎 debe aparecer en **todos** los siguientes lugares sin excepción:

| Lugar | Forma |
|---|---|
| Página del scan (`/scan/:id`) | Header top-left, siempre visible |
| PDF de certificación | Watermark + header prominente |
| PDF del currículum | Header + footer en cada página |
| Página de perfil del técnico | Junto al badge de verificación |
| Emails automáticos | Header del email |
| Terminal del scanner (boot) | ASCII art en la pantalla de inicio |
| ISO boot splash | Logo en la pantalla de arranque |

El logo en el scanner (terminal) ya está como texto — en el frontend debe ser SVG/PNG oficial.
Nunca mostrar el reporte sin el logo. Es la marca que valida el diagnóstico.

---

## Currículum del Técnico

### Schema adicional en Prisma

```prisma
model TechnicianProfile {
  id              String     @id @default(cuid())
  technician_id   String     @unique
  technician      Technician @relation(fields: [technician_id], references: [id])

  // Datos personales
  full_name       String
  title           String?        // ej: "Técnico en Reparación de Equipos de Cómputo"
  phone           String?
  email           String?
  website         String?
  location        String?        // ciudad, país
  languages       String[]       // ["Español", "Inglés"]
  avatar_url      String?

  // Experiencia
  years_experience Int?
  work_history    Json           // [{company, role, from, to, description}]
  education       Json           // [{institution, degree, year}]
  certifications  Json           // [{name, issuer, year, url}]  ← aquí van certs de Platine
  specialties     String[]       // ["MacBook", "laptops gaming", "impresoras"]

  // Stats calculados automáticamente (no los pone el técnico)
  total_repairs   Int    @default(0)
  total_scans     Int    @default(0)   // cuántos scans ha hecho con el USB
  total_votes     Int    @default(0)
  total_views     Int    @default(0)
  member_since    DateTime @default(now())

  // Visibilidad
  public          Boolean @default(true)
  show_phone      Boolean @default(false)
  show_email      Boolean @default(false)

  updated_at      DateTime @updatedAt
}

model PlatineCertification {
  id              String     @id @default(cuid())
  technician_id   String
  technician      Technician @relation(fields: [technician_id], references: [id])

  cert_type       String     // "hardware_scanner" | "community_expert" | "verified_tech"
  cert_number     String     @unique   // ej: "PLT-2026-00142"
  issued_at       DateTime   @default(now())
  expires_at      DateTime?
  pdf_url         String?    // URL del PDF generado en R2
  valid           Boolean    @default(true)

  // Criterios que cumplió para obtenerla
  scans_count     Int?       // cuántos scans tenía cuando se emitió
  repairs_count   Int?
  votes_count     Int?
}
```

### Niveles de Certificación Platine 💎

Los técnicos ganan certificaciones automáticamente al cumplir criterios:

| Certificación | Nombre | Criterio |
|---|---|---|
| 💎 Platine Hardware Scanner | Técnico Certificado Platine | Hacer 1 scan exitoso con el USB |
| 🔧 Platine Repair Contributor | Contribuidor de Reparaciones | Publicar 5+ reparaciones con votos positivos |
| ⭐ Platine Expert | Técnico Experto Platine | 25+ reparaciones, 100+ votos, 1 año activo |
| 🏆 Platine Master | Maestro Platine | 100+ reparaciones, top 5% de votos, verificado |

Cada certificación genera un **PDF único** con número de serie verificable.

### Endpoints de Currículum y Certificación

```
GET  /api/tech/:username/curriculum        → devuelve datos del perfil completo
PUT  /api/tech/me/curriculum               → actualizar currículum propio
GET  /api/tech/:username/curriculum/pdf    → descarga el PDF del currículum
GET  /api/tech/:username/certifications    → lista de certificaciones
POST /api/tech/me/certifications/generate  → genera/regenera PDF de certificación

GET  /api/cert/verify/:cert_number         → página pública de verificación
                                             (QR en el PDF apunta aquí)
```

### PDF del Currículum — Contenido

Generado con `@react-pdf/renderer` o Puppeteer (renderizar una página Next.js a PDF).

```
┌─────────────────────────────────────────────────────┐
│  💎 PLATINE                           platine.dev   │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Juan Carlos Méndez                                 │
│  Técnico en Reparación de Equipos de Cómputo        │
│  📍 Guadalajara, México  |  🌐 juantech.com         │
│                                                     │
├─────────────────────────────────────────────────────┤
│  ESPECIALIDADES                                     │
│  MacBook · Laptops Gaming · Tablets · Impresoras    │
│                                                     │
│  EXPERIENCIA                              8 años    │
│                                                     │
│  TechRepair GDL            2021 – presente          │
│  Técnico Senior                                     │
│  Diagnóstico y reparación de equipos Apple y PC     │
│                                                     │
│  CompuServicio del Norte   2018 – 2021              │
│  Técnico                                            │
│                                                     │
│  EDUCACIÓN                                          │
│  CETIS 123 — Técnico en Informática, 2018           │
│                                                     │
├─────────────────────────────────────────────────────┤
│  CERTIFICACIONES PLATINE                            │
│                                                     │
│  💎 Técnico Certificado Platine         2024        │
│     N° PLT-2024-00042  ✓ Verificado                │
│                                                     │
│  ⭐ Técnico Experto Platine            2025         │
│     N° PLT-2025-00009  ✓ Verificado                │
│                                                     │
├─────────────────────────────────────────────────────┤
│  ESTADÍSTICAS PLATINE (verificadas)                 │
│  147 reparaciones · 3,241 votos · 89,000 vistas     │
│  312 scans realizados · Miembro desde Enero 2024    │
│                                                     │
├─────────────────────────────────────────────────────┤
│  [QR: platine.dev/tech/juanmendez]                  │
│  💎 platine.dev — Verificado el 30/06/2026          │
└─────────────────────────────────────────────────────┘
```

### PDF de Certificación — Contenido

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│              💎 PLATINE                             │
│                                                     │
│         CERTIFICADO DE EXCELENCIA TÉCNICA           │
│                                                     │
│  Este certificado acredita que                      │
│                                                     │
│         JUAN CARLOS MÉNDEZ TORRES                   │
│                                                     │
│  ha completado exitosamente los requisitos para     │
│  obtener la distinción de                           │
│                                                     │
│       ⭐ TÉCNICO EXPERTO PLATINE                    │
│                                                     │
│  Demostrado mediante:                               │
│  · 147 reparaciones documentadas en Platine.dev     │
│  · 3,241 votos positivos de la comunidad            │
│  · 1+ años de actividad continua                    │
│                                                     │
│  Emitido: 15 de Marzo, 2025                         │
│  Número de certificado: PLT-2025-00009              │
│                                                     │
│  [QR de verificación]                               │
│  Verificar en: platine.dev/cert/PLT-2025-00009      │
│                                                     │
│  ────────────────────────────────────────           │
│  💎 Platine — platine.dev                           │
│  Este documento es verificable en línea.            │
└─────────────────────────────────────────────────────┘
```

### Página Pública de Verificación — `/cert/:cert_number`

Cuando alguien escanea el QR del certificado ve:
- ✅ / ❌ si el certificado es válido
- Nombre del técnico
- Tipo de certificación
- Fecha de emisión
- Stats en el momento de la emisión
- Link al perfil del técnico

Esto permite que un cliente o empleador verifique la cert con solo escanear el QR.

---

## Lo que NO hace el Scanner (para no prometer de más)

- No hace test de estrés de RAM (necesita memtest86 — no es posible en shell)
- No mide velocidad de escritura del disco (solo lectura secuencial)
- No diagnostica la pantalla (requeriría framebuffer tests)
- GPU Nvidia: temperatura solo si el driver nouveau la expone (propietario = sin datos)
- iOS/iPhone: no es posible sin libimobiledevice (no incluido)
- SMART en discos externos USB: depende del adaptador, algunos bloquean los comandos
