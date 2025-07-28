# Make sure you are running an Admin PowerShell Session

# Install NuGet provider silently (system-wide)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -Force -Scope CurrentUser

# Set execution policy to allow scripts to run within this session.
# Less Restrictive:  Set-ExecutionPolicy Unrestricted -Scope LocalMachine
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
