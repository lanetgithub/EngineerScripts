# Make sure you are running an Admin PowerShell Session
# Install NuGet provider silently (system-wide)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -Force -Scope CurrentUser

# Ensure PSGallery is trusted
Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted

# Set execution policy to allow scripts to run within this session.
# Less Restrictive :  Set-ExecutionPolicy Unrestricted -Scope LocalMachine
Set-ExecutionPolicy Bypass -Scope Process -Force

#Install CLI
winget install --id Microsoft.AzureCLI -e --accept-package-agreements --accept-source-agreements

# Check if Az module is already installed
if (Get-InstalledModule -Name Az -ErrorAction SilentlyContinue) {
    # Update Az module silently
    Update-Module -Name Az -Force
} else {
    # Install Az module silently
    Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
}

#Install Bicep
winget install Microsoft.Bicep --accept-package-agreements --accept-source-agreements

# Check if Microsoft.Graph is already installed.  This one can take some time to install
if (Get-InstalledModule -Name Microsoft.Graph -ErrorAction SilentlyContinue) {
    # Update silently
    Update-Module -Name Microsoft.Graph -Force
} else {
    # Install silently
    Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers
}

# Install or upgrade VS Code
winget upgrade --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements | winget install --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements

# Install Git for Windows if using DevOps/GitHub Repos
winget install --id Git.Git -e --source winget
winget install GitExtensionsTeam.GitExtension

# Install VS Code extensions but first enable the code app to work so add path details and set it up to run in this session.

# Ensure the script is running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning " Please run this script as Administrator."
    exit
}

# Define the VS Code bin path (System-wide install)
$vsCodePath = "C:\Program Files\Microsoft VS Code\bin"

# Get the current system PATH
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$currentPath = (Get-ItemProperty -Path $regPath -Name Path).Path

# Check if the path is already present
if ($currentPath -notlike "*$vsCodePath*") {
    $newPath = "$currentPath;$vsCodePath"
    Set-ItemProperty -Path $regPath -Name Path -Value $newPath
    Write-Output " VS Code path added to system PATH. A restart or logoff may be required for all users to see the change."
} else {
    Write-Output " VS Code path is already in the system PATH."
}

# Reload system environment variables into the current session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

# Test if 'code' is now available
code --version

# Install VS Code Extensions - Open VS Code in a new Terminal

code --install-extension ms-vscode.vscode-node-azure-pack
code --install-extension ms-vscode.powershell
code --install-extension ms-azuretools.vscode-bicep

# DevOps VS DevOps Code Extensions

code --install-extension hashicorp.terraform                       # Terraform
code --install-extension redhat.vscode-yaml                        # YAML
code --install-extension ms-azuretools.vscode-docker               # Docker
code --install-extension ms-kubernetes-tools.vscode-kubernetes-tools # Kubernetes
code --install-extension github.vscode-github-actions              # GitHub Actions
code --install-extension ms-azure-devops.azure-pipelines           # Azure Pipelines

# Setup GIT in VS Code - Terminal Session

git config --global credentials.helper wincred
git config --global user.name “firstname lastname”
git config --global user.email “youremail@lanet.co.uk”
