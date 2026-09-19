# =============================================================================
# PASO 0: PREPARACIÓN DEL LABORATORIO EN ENTRA ID
# Qué hace: Instala los módulos, conecta a Graph y crea los grupos RBA(CRole-Based Access Control).
# =============================================================================

# 1. Instalamos solo los 5 submódulos que necesitamos (instalar 'Microsoft.Graph' entero tarda muchisimo y no es necesario)
$RequiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Users.Actions",
    "Microsoft.Graph.Groups",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Reports"
)

# El color es para que destaque y probar si funciona
foreach ($Mod in $RequiredModules) {
    if (-not (Get-Module -ListAvailable -Name $Mod)) {
        Write-Host "Instalando módulo $Mod..." -ForegroundColor Cyan 
        Install-Module -Name $Mod -Scope CurrentUser -Force
    }
}

# Nota 1. El primer codigo basico y simple era, el anterior es la mejora para que sea mas eficiente: 
# Write-Host "Instalando módulo Microsoft.Graph completo..." 
# Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force

# 2. Nos conectamos a Entra ID pidiendo los permisos que necesita el script. 
# En este momento me sale una ventana del navegador para iniciar sesión y hay que aceptar los permisos.
# -NoWelcome: Dicen que es buena practica, solo salta el mensaje, si funciona se puede quitar para simplificar
Connect-MgGraph -Scopes @(
    "User.ReadWrite.All",                  # Para crear, modificar y bloquear usuarios
    "Group.ReadWrite.All",                 # Para crear grupos y meter/sacar usuarios
    "Directory.Read.All",                  # Para leer datos generales del directorio
    "AuditLog.Read.All",                   # Obligatorio para ver la fecha de último login (viene en la parte de SignInActivity)
    "UserAuthenticationMethod.Read.All",   # Obligatorio para ver quién tiene MFA configurado (IMPORTANTE)
    "RoleManagement.Read.Directory"        # Obligatorio para ver quién es Global Admin u otro rol crítico
) -NoWelcome    

# 3. Creamos los grupos de seguridad (RBAC) en Entra ID 
# Cuidado! crear el grupo para todos que no se olvide como antes
$GroupsToCreate = @(
    "SG-RBAC-AllEmployees",  
    "SG-RBAC-Human-Resources",
    "SG-RBAC-SecOps",
    "SG-RBAC-IT-Infrastructure"
)
#Fallo 1: Crearlo sin espacios, que da error

foreach ($GroupName in $GroupsToCreate) {
    # Buscamos si el grupo ya existe para no duplicarlo y se guarda si es que si
    $ExistingGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
    
    if (-not $ExistingGroup) {
        # MailEnabled:$false y SecurityEnabled:$true indica que es un Grupo de Seguridad puro (no un grupo de correo)
        # MailNickname: Es obligatorio aunque no haya correo, dejamos el nombre propiamente del grupo sin las -
        # Out-Null: Como nowelcome para quitar la impresion auto en pantalla
        New-MgGroup -DisplayName $GroupName `
                    -Description "Grupo de acceso RBAC gestionado por automatización JML" `
                    -MailEnabled:$false `
                    -MailNickname ($GroupName) `
                    -SecurityEnabled:$true | Out-Null
        
        Write-Host "[OK] Grupo creado en Entra ID: $GroupName" -ForegroundColor Green
    } else {
        Write-Host "[INFO] El grupo $GroupName ya existe." -ForegroundColor Red
    }
}