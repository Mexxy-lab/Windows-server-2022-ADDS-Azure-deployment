# Configuring sonarqube to jenkins server

A. Install the Jenkins SonarQube plugin

- Go to Manage Jenkins → Plugins → Available plugins.

- Search for and install: SonarQube Scanner for Jenkins Restart Jenkins if requested.

B. Configure the SonarQube server

- Go to Manage Jenkins → System → SonarQube installations.

Add an installation:

Setting                                 Value
Name                                    SonarQube
Server URL                              <http://192.168.1.112:9000>
Server authentication token             Your SonarQube Jenkins token (Create this from sonarqube)

- Create a SonarQube token from your SonarQube account under My Account → Security → Generate Tokens, then add it to Jenkins as a Secret text credential and select it in the server configuration.

C. Configure the SonarScanner tool

- Go to Manage Jenkins → Tools → SonarQube Scanner installations.
- This (SonarScanner) name must match the Jenkinsfile's tool 'SonarScanner' declaration.

Setting                                   Value
Name                                      SonarScanner
Install automatically                     Checked

D. Configure the SonarQube webhook

- This is important because Jenkins needs to receive the Quality Gate result.

In SonarQube:

1. Go to Administration → Configuration → Webhooks.
2. Add a webhook.
3. Set its URL to: <http://YOUR-JENKINS-SERVER:8080/sonarqube-webhook/>

## What is SSM?

- SSM stands for AWS Systems Manager. It is an AWS service that lets you remotely manage and administer servers and virtual machines without needing to expose them to the internet or open SSH/RDP ports.

- Think of it as AWS's secure remote-management system. What does SSM do?

Feature                           Purpose
Session Manager                   Connect to Linux and Windows servers remotely without SSH or RDP.
Run Command                       Execute commands or PowerShell scripts remotely.
Patch Manager                     Automate operating system patching.
Fleet Manager                     Manage and monitor EC2 instances.
Parameter Store                   Securely store configuration values and application parameters.
Automation                        Automate administrative tasks and operational procedures.

## How SSM works in your AWS Windows AD project

- Your architecture uses SSM to manage your Windows Domain Controller and Windows client in private subnets.
- Here's what happens during your deployment:

1. Terraform provisions your Windows EC2 instances.
2. Each Windows instance runs the SSM Agent.
3. The SSM Agent establishes outbound communication with AWS Systems Manager.
4. Your Jenkins server uses the AWS CLI and Session Manager plugin to establish SSM port-forwarding sessions.
5. Ansible connects through those tunnels to configure Active Directory and join the Windows client to the domain.

## Why SSM is valuable for DevOps

- SSM is an important cloud infrastructure security skill because it helps you:

- Avoid exposing SSH (22) and RDP (3389) to the public internet.
- Centrally manage EC2 instances.
- Execute remote commands through automation.
- Integrate secure server administration into Jenkins pipelines.
- Reduce the need for traditional bastion hosts.

```bash
trivy config \
    --misconfig-scanners=terraform \
    --severity HIGH,CRITICAL \
    --format json \
    --output trivy-report.json \
    .

jq -r '
  .Results[]?.Misconfigurations[]?
  | [
      .ID,
      .Severity,
      .CauseMetadata.Resource,
      .CauseMetadata.Code.Lines[0].Number,
      .CauseMetadata.Code.Lines[-1].Number
    ]
  | @tsv
' trivy-report.json

jq -r '
  [.Results[]?.Misconfigurations[]?]
  | group_by(.Severity)
  | map("\(.[0].Severity): \(length)")
  | .[]
' trivy-report.json
```

🚀 **Portfolio Project: Automated Windows Server 2022 Active Directory Deployment on AWS**

I’m excited to share a hands-on cloud infrastructure and DevOps project I’ve been building: **Windows Server 2022 AD DS Auto Deployment on AWS.**

The goal was to automate the deployment of a Windows Active Directory environment using Infrastructure as Code, configuration management, and CI/CD — while keeping the Windows servers private and minimizing manual administration.

☁️ **Project Architecture & Technologies**

🔹 **AWS** – VPC, public and private subnets, EC2, IAM, Systems Manager, Secrets Manager  
🔹 **Terraform** – Automated infrastructure provisioning  
🔹 **Ansible & PowerShell** – Windows configuration, AD DS installation, DNS, OU creation, and domain user automation  
🔹 **AWS Systems Manager** – Private server management and temporary port forwarding  
🔹 **WinRM over HTTPS** – Secure Ansible communication with Windows hosts  
🔹 **Jenkins** – CI/CD pipeline with deployment and destruction workflows  
🔹 **Trivy** – Infrastructure-as-Code and security scanning  
🔹 **SonarQube** – Static code analysis and quality gate integration  
🔹 **GitHub** – Source control and project documentation  

🛡️ **Security-Focused Design**

The Windows instances are deployed in a private subnet without direct public IP exposure. AWS Systems Manager is used for remote management, while a Linux NAT instance provides controlled outbound connectivity.

Sensitive automation data is protected using Ansible Vault and Jenkins credentials.

⚙️ **What I Automated**

✅ Provisioned AWS infrastructure with Terraform  
✅ Deployed and configured Windows Server 2022  
✅ Installed and configured Active Directory Domain Services  
✅ Automated DNS, organizational units, and domain user creation  
✅ Validated Windows remoting and domain connectivity  
✅ Built a Jenkins pipeline with Trivy and SonarQube integration  
✅ Added parameterized `APPLY` and `DESTROY` workflows with approval gates  
✅ Documented deployment, validation, and troubleshooting procedures  

The AWS deployment has successfully completed its infrastructure and Active Directory validation. I’m currently finalizing the Jenkins execution environment and preparing to extend the project into **Azure**, bringing the automation toward a multi-cloud implementation.

This project has been a great opportunity to strengthen my practical skills in cloud infrastructure, Windows administration, automation, networking, and DevSecOps.

📌 **Next milestone:** Azure AD DS environment deployment with Terraform, Ansible, and Jenkins.

## AWS #DevOps #CloudEngineering #Terraform #Ansible #Jenkins #WindowsServer #ActiveDirectory #DevSecOps #Trivy #SonarQube #InfrastructureAsCode #Automation #CloudSecurity #PortfolioProject
