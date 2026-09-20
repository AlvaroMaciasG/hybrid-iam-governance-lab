<#
.SYNOPSIS
    Laboratorio JML (Joiner, Mover, Leaver) con Microsoft Entra ID.

.DESCRIPTION
    Lee un CSV de RRHH y, para cada empleado, decide qué hacer:
      - NO existe en Entra ID y está "Active"  -> JOINER: lo crea y lo mete en sus grupos.
      - Existe y está "Active"                 -> MOVER:  actualiza sus datos y cambia sus grupos si hace falta.
      - Existe y está "Terminated"             -> LEAVER: lo deshabilita y le quita los grupos.

    Con -DryRun solo simula: escribe lo que haría, pero NO cambia nada en Entra ID.

    Columnas que debe tener el CSV:
      UserPrincipalName, DisplayName, GivenName, Surname, EmployeeID, Department, JobTitle, AccountStatus

    Antes de ejecutarlo, conéctate a Graph:
      Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","GroupMember.ReadWrite.All","User.RevokeSessions.All"

.EXAMPLE
    .\New-JMLProvisioning.ps1 -CsvPath .\hr_sample.csv -DryRun

.EXAMPLE
    .\New-JMLProvisioning.ps1 -CsvPath .\hr_sample.csv
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [string]$LogFolder = "$PSScriptRoot/logs",

    [switch]$DryRun
)

# Si algo falla, que salte al bloque catch en vez de seguir como si nada
$ErrorActionPreference = "Stop"


# =============================================================================
# FUNCIÓN 1: Escribir logs (en pantalla y en un archivo .jsonl)
# =============================================================================
# JSONL = una línea JSON por evento. Es el formato que un SIEM (Wazuh, Sentinel...) lee fácilmente.
function Write-Log {
    param (
        [string]$Level,    # INFO, AUDIT, WARN, ERROR
        [string]$Action,   # JOINER_CREATED, MOVER_UPDATED, LEAVER_DISABLED...
        [string]$User,     # UPN del usuario afectado
        [string]$Details   # Qué ha pasado
    )

    # Si la carpeta de logs no existe, se crea
    if (-not (Test-Path $LogFolder)) {
        New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
    }
    $LogFile = Join-Path $LogFolder "jml_$(Get-Date -Format 'yyyyMMdd').jsonl"

    $Entry = [ordered]@{
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Level     = $Level
        Action    = $Action
        User      = $User
        Details   = $Details
        DryRun    = [bool]$DryRun
    }
    ($Entry | ConvertTo-Json -Compress) | Out-File -FilePath $LogFile -Append -Encoding utf8

    # Color según el nivel, para leerlo mejor en consola
    $Color = switch ($Level) {
        "AUDIT" { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$($Entry.Timestamp)] [$Level] [$Action] $User -> $Details" -ForegroundColor $Color
}


# =============================================================================
# FUNCIÓN 2: Generar una contraseña temporal
# =============================================================================
# 12 caracteres aleatorios + "Aa1!" al final para cumplir siempre la complejidad de Entra ID.
function New-TempPassword {
    $Chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".ToCharArray()
    $RandomPart = -join (1..12 | ForEach-Object { $Chars | Get-Random })
    return $RandomPart + "Aa1!"
}


# =============================================================================
# PASO 1: Comprobaciones iniciales y preparar los grupos
# =============================================================================
if (-not (Get-MgContext)) {
    throw "No estás conectado a Microsoft Graph. Ejecuta 'Connect-MgGraph' primero."
}

# Relación: Departamento del CSV -> Grupo RBAC en Entra ID
$DepartmentToGroupMap = @{
    "Human-Resources"  = "SG-RBAC-Human-Resources"
    "SecOps"            = "SG-RBAC-SecOps"
    "IT-Infrastructure" = "SG-RBAC-IT-Infrastructure"
}
$AllEmployeesGroupName = "SG-RBAC-AllEmployees"

# Buscamos el ID de cada grupo UNA sola vez y lo guardamos (así no consultamos Entra por cada empleado)
$GroupIds = @{}
foreach ($GroupName in ($DepartmentToGroupMap.Values + $AllEmployeesGroupName)) {
    $Group = Get-MgGroup -Filter "displayName eq '$GroupName'"
    if (-not $Group) {
        throw "No se encuentra el grupo '$GroupName' en Entra ID. Ejecuta primero 00-Setup-LabEnvironment.ps1"
    }
    $GroupIds[$GroupName] = $Group.Id
}
$AllEmployeesGroupId = $GroupIds[$AllEmployeesGroupName]


# =============================================================================
# PASO 2: Leer el CSV y procesar cada empleado
# =============================================================================
# Si tu CSV viene de Excel en español, puede usar ";" como separador.
# En ese caso: Import-Csv -Path $CsvPath -Delimiter ";" -Encoding UTF8
$HrUsers = Import-Csv -Path $CsvPath -Encoding UTF8

foreach ($Row in $HrUsers) {

    $UPN = $Row.UserPrincipalName.Trim()

    # Grupo que le corresponde según su departamento (si el departamento no está en el mapa, queda vacío)
 
$TargetGroupName = $DepartmentToGroupMap[$Row.Department]
$TargetGroupId   = if ($TargetGroupName) { $GroupIds[$TargetGroupName] } else { $null }
    try {
        # Buscamos al usuario en Entra ID. Las comillas simples se duplican para que no rompan el filtro.
        # Con -Property pedimos los campos que nos interesan (por defecto Graph no devuelve todos).
        $SafeUPN   = $UPN.Replace("'", "''")
        $EntraUser = Get-MgUser -Filter "userPrincipalName eq '$SafeUPN'" `
                                -Property Id, UserPrincipalName, Department, JobTitle, AccountEnabled

        # ---------------------------------------------------------------------
        # CASO 1: JOINER -> no existe en Entra ID y en el CSV está Active
        # ---------------------------------------------------------------------
        if (-not $EntraUser -and $Row.AccountStatus -eq "Active") {

            if ($DryRun) {
                Write-Log "INFO" "JOINER_DRYRUN" $UPN "Se crearía el usuario y se añadiría a '$TargetGroupName'."
            }
            else {
                $TempPassword = New-TempPassword

                # Agrupamos los parámetros en una tabla (splatting): es más legible que usar ` al final de cada línea
                $NewUserParams = @{
                    DisplayName       = $Row.DisplayName
                    GivenName         = $Row.GivenName
                    Surname           = $Row.Surname
                    UserPrincipalName = $UPN
                    MailNickname      = $UPN.Split("@")[0]
                    EmployeeId        = $Row.EmployeeID
                    Department        = $Row.Department
                    JobTitle          = $Row.JobTitle
                    UsageLocation     = "ES"
                    AccountEnabled    = $true
                    PasswordProfile   = @{
                        Password                      = $TempPassword
                        ForceChangePasswordNextSignIn = $true   # Tendrá que cambiarla al entrar
                    }
                }
                $NewUser = New-MgUser @NewUserParams
                Write-Log "AUDIT" "JOINER_CREATED" $UPN "Usuario creado (Dept: $($Row.Department))."

                # La contraseña solo se muestra en pantalla, NUNCA se guarda en el log
                Write-Host "    Contraseña temporal de $UPN : $TempPassword" -ForegroundColor Magenta

                # Grupo general de empleados + grupo de su departamento
                New-MgGroupMember -GroupId $AllEmployeesGroupId -DirectoryObjectId $NewUser.Id
                Write-Log "AUDIT" "JOINER_GROUP_ADD" $UPN "Añadido a '$AllEmployeesGroupName'."

                if ($TargetGroupId) {
                    New-MgGroupMember -GroupId $TargetGroupId -DirectoryObjectId $NewUser.Id
                    Write-Log "AUDIT" "JOINER_GROUP_ADD" $UPN "Añadido a '$TargetGroupName'."
                }
                else {
                    Write-Log "WARN" "JOINER_NO_DEPT_GROUP" $UPN "El departamento '$($Row.Department)' no está en el mapa de grupos."
                }
            }
        }

        # ---------------------------------------------------------------------
        # CASO 2: MOVER -> ya existe y sigue Active
        # ---------------------------------------------------------------------
        elseif ($EntraUser -and $Row.AccountStatus -eq "Active") {

            # 2A. ¿Ha cambiado su departamento o su puesto?
            $HasChanged = ($EntraUser.Department -ne $Row.Department) -or ($EntraUser.JobTitle -ne $Row.JobTitle)

            if (-not $HasChanged) {
                Write-Log "INFO" "NO_CHANGES" $UPN "Sus datos ya están al día."
            }
            elseif ($DryRun) {
                Write-Log "INFO" "MOVER_DRYRUN" $UPN "Se cambiaría Dept '$($EntraUser.Department)' -> '$($Row.Department)'."
            }
            else {
                Update-MgUser -UserId $EntraUser.Id -Department $Row.Department -JobTitle $Row.JobTitle
                Write-Log "AUDIT" "MOVER_UPDATED" $UPN "Dept '$($EntraUser.Department)' -> '$($Row.Department)'."
            }

            # 2B. Grupos: añadir el nuevo y quitar los de otros departamentos (evita el "privilege creep")
            if (-not $TargetGroupId) {
                # Importante: si no conocemos el departamento, NO tocamos sus grupos (así no le quitamos accesos por error)
                Write-Log "WARN" "MOVER_NO_DEPT_GROUP" $UPN "El departamento '$($Row.Department)' no está en el mapa. No se tocan sus grupos."
            }
            else {
                $CurrentGroups = (Get-MgUserMemberOf -UserId $EntraUser.Id -All).Id

                # Añadir el grupo de su departamento si aún no está dentro
                if ($CurrentGroups -notcontains $TargetGroupId) {
                    if (-not $DryRun) {
                        New-MgGroupMember -GroupId $TargetGroupId -DirectoryObjectId $EntraUser.Id
                    }
                    Write-Log "AUDIT" "MOVER_GROUP_ADD" $UPN "Añadido a '$TargetGroupName'."
                }

                # Quitar cualquier otro grupo de departamento al que pertenezca
                foreach ($OtherGroupName in $DepartmentToGroupMap.Values) {
                    $OtherGroupId = $GroupIds[$OtherGroupName]

                    if (($OtherGroupId -ne $TargetGroupId) -and ($CurrentGroups -contains $OtherGroupId)) {
                        if (-not $DryRun) {
                            Remove-MgGroupMemberByRef -GroupId $OtherGroupId -DirectoryObjectId $EntraUser.Id
                        }
                        Write-Log "AUDIT" "MOVER_GROUP_REMOVE" $UPN "Eliminado de '$OtherGroupName'."
                    }
                }
            }
        }

        # ---------------------------------------------------------------------
        # CASO 3: LEAVER -> existe y en el CSV está Terminated
        # ---------------------------------------------------------------------
        elseif ($EntraUser -and $Row.AccountStatus -eq "Terminated") {

            # 3A. Bloquear la cuenta y cerrar sus sesiones abiertas
            if ($EntraUser.AccountEnabled -eq $true) {
                if (-not $DryRun) {
                    Update-MgUser -UserId $EntraUser.Id -AccountEnabled:$false
                    Revoke-MgUserSignInSession -UserId $EntraUser.Id | Out-Null
                }
                Write-Log "AUDIT" "LEAVER_DISABLED" $UPN "Cuenta deshabilitada y sesiones revocadas."
            }
            else {
                Write-Log "INFO" "LEAVER_ALREADY_DISABLED" $UPN "La cuenta ya estaba deshabilitada."
            }

            # 3B. Quitarle todos los grupos RBAC
            $CurrentGroups = (Get-MgUserMemberOf -UserId $EntraUser.Id -All).Id

            foreach ($GroupName in $GroupIds.Keys) {
                $GroupId = $GroupIds[$GroupName]

                if ($CurrentGroups -contains $GroupId) {
                    if (-not $DryRun) {
                        Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $EntraUser.Id
                    }
                    Write-Log "AUDIT" "LEAVER_GROUP_REMOVE" $UPN "Eliminado de '$GroupName'."
                }
            }
        }

        # ---------------------------------------------------------------------
        # CASO 4: Terminated y ya no existe -> no hay nada que hacer
        # ---------------------------------------------------------------------
        elseif (-not $EntraUser -and $Row.AccountStatus -eq "Terminated") {
            Write-Log "INFO" "LEAVER_SKIP" $UPN "Dado de baja y ya no existe en Entra ID."
        }

        # ---------------------------------------------------------------------
        # CASO 5: Estado desconocido en el CSV
        # ---------------------------------------------------------------------
        else {
            Write-Log "WARN" "UNKNOWN_STATUS" $UPN "AccountStatus '$($Row.AccountStatus)' no reconocido. Se ignora."
        }
    }
    catch {
        # Si falla un usuario, lo registramos y seguimos con el siguiente
        Write-Log "ERROR" "EXCEPTION" $UPN $_.Exception.Message
    }
}