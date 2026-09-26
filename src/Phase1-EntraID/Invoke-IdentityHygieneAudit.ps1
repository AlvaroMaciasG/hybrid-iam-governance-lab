<#
.SYNOPSIS
    Auditoría de higiene de identidades en Microsoft Entra ID (solo lectura).

.DESCRIPTION
    Revisa todos los usuarios y busca tres riesgos:
      1. Cuentas activas que llevan más de X días sin iniciar sesión (por defecto 90).
      2. Cuentas activas sin MFA registrado.
      3. Usuarios con un rol de administrador crítico.

    A cada usuario le asigna un nivel de riesgo (CRITICAL, HIGH, MEDIUM o LOW)
    y guarda el resultado en un CSV (para Excel) y en un JSON (para automatizar).
    No modifica nada en Entra ID: solo lee y escribe los informes en local.

    Hecho con ayuda de IA; cada bloque lleva una nota de lo que hace.

    Requisitos:
      - Estar conectado a Graph. Si 00-Setup-LabEnvironment.ps1 se ejecutó en esta
        misma ventana, ya vale. Si no:
        Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","RoleManagement.Read.Directory"
      - SignInActivity y el informe de MFA necesitan licencia Entra ID P1/P2 (o trial).

.EXAMPLE
    .\Invoke-IdentityHygieneAudit.ps1

.EXAMPLE
    .\Invoke-IdentityHygieneAudit.ps1 -InactiveDays 0
    # Con 0 días, casi cualquier cuenta habilitada sale como inactiva.
    # Sirve para ver la lógica funcionando en un lab recién creado.
#>
param (
    # Días sin iniciar sesión para considerar una cuenta "abandonada"
    [int]$InactiveDays = 90,

    # Carpeta donde se guardan los informes
    [string]$ReportFolder = "$PSScriptRoot/reports"
)

# Si algo falla, que se pare y salte al catch
$ErrorActionPreference = "Stop"

if (-not (Get-MgContext)) {
    throw "No estás conectado a Microsoft Graph. Ejecuta 'Connect-MgGraph' primero."
}

if (-not (Test-Path $ReportFolder)) {
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
}

# Fecha límite: hoy menos $InactiveDays días.
# Si el último login es anterior a esta fecha, la cuenta se considera inactiva.
$CutoffDate = (Get-Date).AddDays(-$InactiveDays)
$DateStamp  = Get-Date -Format "yyyyMMdd_HHmm"


# =============================================================================
# PASO 1: Descargar los usuarios con su último inicio de sesión
# =============================================================================
Write-Host "[1/5] Descargando usuarios y su último inicio de sesión..." -ForegroundColor Cyan

# -All trae todos los usuarios (sin él, Graph devuelve solo la primera página).
# -Property pide los campos que necesito; SignInActivity no viene por defecto.
try {
    $Users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Department, AccountEnabled, CreatedDateTime, SignInActivity
}
catch {
    throw "No se pudo leer SignInActivity (¿licencia P1/P2? ¿permiso AuditLog.Read.All?). Detalle: $($_.Exception.Message)"
}


# =============================================================================
# PASO 2: Averiguar quién tiene MFA registrado
# =============================================================================
Write-Host "[2/5] Consultando el estado de MFA..." -ForegroundColor Cyan

# Diccionario: ID del usuario -> True/False (¿tiene MFA?).
# Con un diccionario, en el paso 4 busco por ID directamente en vez de recorrer una lista.
$MfaStatusByUser = @{}

# Si esto falla, el script sigue: simplemente no sabremos el estado de MFA de nadie.
# TODO: confirmar en la documentación de Graph qué permiso exige exactamente este informe.
try {
    $MfaReport = Get-MgReportAuthenticationMethodUserRegistrationDetail -All
    foreach ($Item in $MfaReport) {
        $MfaStatusByUser[$Item.Id] = $Item.IsMfaRegistered
    }
}
catch {
    Write-Warning "No se pudo leer el informe de MFA. Revisa el permiso AuditLog.Read.All, la licencia P1/P2 y que tu usuario pueda leer informes. Detalle: $($_.Exception.Message)"
}


# =============================================================================
# PASO 3: Averiguar quién tiene roles de administrador críticos
# =============================================================================
Write-Host "[3/5] Revisando los roles de administrador..." -ForegroundColor Cyan

$CriticalRoleNames = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Security Administrator",
    "User Administrator",
    "Application Administrator"
)

# Diccionario: ID del usuario -> texto con sus roles ("Rol1, Rol2")
$AdminRolesByUser = @{}

# Get-MgDirectoryRole solo devuelve los roles ya activados en el tenant.
# Solo consulto los miembros de los roles críticos, no los de todos.
# TODO: los roles "elegibles" de PIM no aparecen aquí, solo las asignaciones activas.
foreach ($Role in (Get-MgDirectoryRole -All)) {
    if ($CriticalRoleNames -contains $Role.DisplayName) {
        $Members = Get-MgDirectoryRoleMember -DirectoryRoleId $Role.Id -All

        foreach ($Member in $Members) {
            if ($AdminRolesByUser.ContainsKey($Member.Id)) {
                # Ya tenía otro rol: añado este detrás
                $AdminRolesByUser[$Member.Id] += ", " + $Role.DisplayName
            }
            else {
                $AdminRolesByUser[$Member.Id] = $Role.DisplayName
            }
        }
    }
}


# =============================================================================
# PASO 4: Analizar usuario por usuario y calcular el riesgo
# =============================================================================
Write-Host "[4/5] Analizando riesgos..." -ForegroundColor Cyan

# El foreach devuelve una fila por usuario y @( ) asegura que el resultado sea
# siempre una lista, aunque solo haya un usuario.
$ReportData = @(foreach ($U in $Users) {

    # 4.1 Último acceso: el más reciente entre el interactivo (una persona
    # entrando) y el no interactivo (apps que renuevan sesión en segundo plano).
    $LastLogin          = $U.SignInActivity.LastSignInDateTime
    $LastNonInteractive = $U.SignInActivity.LastNonInteractiveSignInDateTime

    if ($LastNonInteractive -and (-not $LastLogin -or $LastNonInteractive -gt $LastLogin)) {
        $LastLogin = $LastNonInteractive
    }

    # 4.2 ¿Inactiva? Solo miro cuentas habilitadas.
    # Si nunca ha entrado, es sospechosa solo si se creó hace más de $InactiveDays días.
    $IsInactive = $false

    if ($U.AccountEnabled) {
        if ($LastLogin) {
            $IsInactive = ($LastLogin -lt $CutoffDate)
        }
        else {
            $IsInactive = ($U.CreatedDateTime -lt $CutoffDate)
        }
    }

    # 4.3 ¿Le falta MFA? Uso -eq $false (y no -not) porque si el informe de MFA
    # falló, $HasMfa está vacío; con -not marcaría a todos como "sin MFA".
    $HasMfa     = $MfaStatusByUser[$U.Id]
    $MissingMfa = $U.AccountEnabled -and ($HasMfa -eq $false)

    # 4.4 ¿Es administrador crítico?
    $IsPrivileged = $AdminRolesByUser.ContainsKey($U.Id)
    $AdminRoles   = "None"

    if ($IsPrivileged) {
        $AdminRoles = $AdminRolesByUser[$U.Id]
    }

    # 4.5 Nivel de riesgo. Va de más grave a menos grave y gana el primero que se cumple.
    #   CRITICAL : administrador y además sin MFA o inactivo
    #   HIGH     : administrador, o usuario activo sin MFA
    #   MEDIUM   : usuario normal con la cuenta abandonada
    #   LOW      : todo correcto
    $RiskLevel = "LOW"

    if ($IsPrivileged -and ($MissingMfa -or $IsInactive)) {
        $RiskLevel = "CRITICAL"
    }
    elseif ($IsPrivileged -or $MissingMfa) {
        $RiskLevel = "HIGH"
    }
    elseif ($IsInactive) {
        $RiskLevel = "MEDIUM"
    }

    # 4.6 Fechas como texto: en Windows PowerShell 5.1, ConvertTo-Json serializa
    # las fechas con un formato raro (/Date(123456)/); como texto salen legibles.
    $LastLoginText = "Never"
    if ($LastLogin) {
        $LastLoginText = $LastLogin.ToString("yyyy-MM-dd HH:mm")
    }

    $CreatedText = ""
    if ($U.CreatedDateTime) {
        $CreatedText = $U.CreatedDateTime.ToString("yyyy-MM-dd")
    }

    # Fila del informe
    [PSCustomObject]@{
        UserPrincipalName = $U.UserPrincipalName
        DisplayName       = $U.DisplayName
        Department        = $U.Department
        AccountEnabled    = $U.AccountEnabled
        CreatedDate       = $CreatedText
        LastSignInDate    = $LastLoginText
        IsInactive        = $IsInactive
        MfaRegistered     = $HasMfa
        PrivilegedRoles   = $AdminRoles
        RiskLevel         = $RiskLevel
    }
})


# =============================================================================
# PASO 5: Guardar los informes
# =============================================================================
Write-Host "[5/5] Guardando informes..." -ForegroundColor Cyan

$CsvFile  = Join-Path $ReportFolder "Identity_Hygiene_Audit_$DateStamp.csv"
$JsonFile = Join-Path $ReportFolder "Identity_Hygiene_Audit_$DateStamp.json"

# -UseCulture usa el separador de listas del sistema (en español, ";"), para que
# Excel separe bien las columnas al abrir el CSV.
$ReportData | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding utf8 -UseCulture

# -InputObject (y no la tubería) para que salga siempre como lista JSON
ConvertTo-Json -InputObject $ReportData -Depth 3 | Out-File -FilePath $JsonFile -Encoding utf8

Write-Host "`n[OK] Auditoría finalizada. Archivos generados:" -ForegroundColor Green
Write-Host " -> CSV : $CsvFile"
Write-Host " -> JSON: $JsonFile"

# Resumen rápido: cuántos usuarios hay en cada nivel de riesgo
Write-Host "`nResumen por nivel de riesgo:"
$ReportData | Group-Object RiskLevel | Select-Object Name, Count | Format-Table -AutoSize
