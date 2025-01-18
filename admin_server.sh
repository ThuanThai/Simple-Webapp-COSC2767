#!/bin/bash
# Set hostname
HOSTNAME="admin-server"
hostnamectl set-hostname "${HOSTNAME}"

# Update packages
yum update -y

# Allocate 3GB of temp space
echo "tmpfs /tmp tmpfs defaults,size=3G 0 0" >> /etc/fstab
mount -o remount /tmp

# Install necessary packages
yum install -y git aws-cli wget nano

# Store values in SSM Parameter Store
aws ssm put-parameter --region us-east-1 --name "/admin/private-ip" --value "us-east-1" --type String --overwrite

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Install Jenkins
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
yum install fontconfig java-17-amazon-corretto -y
yum install jenkins -y

# Modify /etc/default/jenkins to bypass setup wizard
echo 'JAVA_ARGS="-Djenkins.install.runSetupWizard=false -Dorg.apache.commons.jelly.tags.fmt.timeZone=Asia/Saigon"' >> /etc/default/jenkins

# Create init.groovy.d directory and add basic-security.groovy
mkdir -p /var/lib/jenkins/init.groovy.d
cat <<'EOF' > /var/lib/jenkins/init.groovy.d/basic-security.groovy
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// Configure security realm
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount("admin", "s3cret")
instance.setSecurityRealm(hudsonRealm)

// Configure authorization strategy
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// Save configuration
instance.save()
EOF

# Ensure correct ownership of Jenkins directories
chown -R jenkins:jenkins /var/lib/jenkins

# Start Jenkins
systemctl enable jenkins
systemctl start jenkins


# Download Jenkins CLI
wget -O /var/lib/jenkins/jenkins-cli.jar http://localhost:8080/jnlpJars/jenkins-cli.jar
chown jenkins:jenkins /var/lib/jenkins/jenkins-cli.jar

# Install plugins using Jenkins CLI
declare -a PluginList=(
    "github"
    "dark-theme"
    "publish-over-ssh"
    "workflow-aggregator"
    "docker-workflow"
)

echo "Installing plugins..."
for plugin in $${PluginList[@]}; do
    java -jar /var/lib/jenkins/jenkins-cli.jar -auth admin:s3cret -s http://localhost:8080/ install-plugin $$plugin
done

# Restart Jenkins to apply plugins
java -jar /var/lib/jenkins/jenkins-cli.jar -auth admin:s3cret -s http://localhost:8080/ restart

# Install Docker
yum install -y docker
systemctl enable docker
systemctl start docker

# Add Jenkins user to docker group
usermod -aG docker jenkins

# Optional: Install Ansible
yum install -y ansible

# Install Python and Boto for Dynamic Inventory
yum install python3-pip -y
pip install boto3

# Create Ansible Config file
ansible-config init --disabled > /etc/ansible/ansible.cfg

# Create ansibleadmin user
useradd ansibleadmin
usermod -aG docker ansibleadmin
echo "ansibleadmin:s3cret" | chpasswd

# Allow passwordless sudo for ansibleadmin
echo "ansibleadmin ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Enable password authentication for SSH
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Set up SSH for ansibleadmin
sudo -u ansibleadmin bash <<EOF
mkdir -p /home/ansibleadmin/.ssh
ssh-keygen -t rsa -b 2048 -f /home/ansibleadmin/.ssh/id_rsa -q -N ""
cat /home/ansibleadmin/.ssh/id_rsa.pub >> /home/ansibleadmin/.ssh/authorized_keys
EOF
aws ssm put-parameter --region us-east-1 --name "/admin/ssh-key" --value "$(cat /home/ansibleadmin/.ssh/id_rsa.pub)" --type String --overwrite
chown -R ansibleadmin:ansibleadmin /home/ansibleadmin/.ssh
chmod 600 /home/ansibleadmin/.ssh/id_rsa
chmod 644 /home/ansibleadmin/.ssh/id_rsa.pub
chmod 600 /home/ansibleadmin/.ssh/authorized_keys
