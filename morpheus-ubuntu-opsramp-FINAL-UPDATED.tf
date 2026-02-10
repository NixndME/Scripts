# ============================================================================
# Morpheus Demo: RDS PostgreSQL + Ubuntu EC2 with OpsRamp
# ============================================================================
# Complete solution with OpsRamp agent installation via user-data
# ============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# ============================================================================
# VARIABLES
# ============================================================================

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

# ============================================================================
# RANDOM SUFFIX
# ============================================================================

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ============================================================================
# SECURITY GROUPS
# ============================================================================

resource "aws_security_group" "web_sg" {
  name        = "demo-web-${random_string.suffix.result}"
  description = "Web server access"
  vpc_id      = "vpc-0b9b782aa111c0bde"
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "Demo-Web"
  }
}

resource "aws_security_group" "db_sg" {
  name        = "demo-db-${random_string.suffix.result}"
  description = "Database access from web"
  vpc_id      = "vpc-0b9b782aa111c0bde"
  
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "Demo-DB"
  }
}

# ============================================================================
# RDS SUBNET GROUP
# ============================================================================

resource "aws_db_subnet_group" "db_subnet" {
  name       = "demo-db-subnet-${random_string.suffix.result}"
  subnet_ids = [
    "subnet-04027f0848e3d6ddc",
    "subnet-054ec56f89ed69000"
  ]
  
  tags = {
    Name = "Demo-DB-Subnet"
  }
}

# ============================================================================
# RDS POSTGRESQL
# ============================================================================

resource "aws_db_instance" "postgres" {
  identifier     = "demo-db-${random_string.suffix.result}"
  
  engine         = "postgres"
  engine_version = "15.10"
  instance_class = "db.t3.micro"
  
  allocated_storage = 20
  storage_type      = "gp3"
  
  db_name  = "demodb"
  username = "demoadmin"
  password = var.db_password
  
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible    = true
  
  skip_final_snapshot = true
  deletion_protection = false
  
  tags = {
    Name = "Demo-DB"
  }
}

# ============================================================================
# UBUNTU AMI
# ============================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ============================================================================
# EC2 WEB SERVER (UBUNTU)
# ============================================================================

resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  
  subnet_id                   = "subnet-04027f0848e3d6ddc"
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  
  user_data = <<-EOF
              #!/bin/bash
              set -x
              exec > >(tee /var/log/user-data.log)
              exec 2>&1
              
              echo "=========================================="
              echo "Starting User-Data Script"
              echo "Hostname: $(hostname)"
              echo "Date: $(date)"
              echo "=========================================="
              
              # Update system
              apt-get update
              
              # Install Apache and PHP
              apt-get install -y apache2 php libapache2-mod-php php-pgsql postgresql-client
              
              # Create database status page
              cat > /var/www/html/index.php << 'PHP'
              <!DOCTYPE html>
              <html>
              <head>
                  <title>Database Status Monitor</title>
                  <meta http-equiv="refresh" content="10">
                  <style>
                      body { font-family: Arial; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
                             display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
                      .container { background: white; padding: 40px; border-radius: 20px; 
                                   box-shadow: 0 20px 60px rgba(0,0,0,0.3); max-width: 500px; text-align: center; }
                      .status { padding: 30px; border-radius: 10px; margin: 20px 0; }
                      .connected { background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%); color: white; }
                      .disconnected { background: linear-gradient(135deg, #eb3349 0%, #f45c43 100%); color: white; }
                      .icon { font-size: 60px; margin-bottom: 20px; }
                      h1 { margin: 0 0 20px 0; }
                      .info { background: #f5f5f5; padding: 15px; border-radius: 8px; margin-top: 20px; text-align: left; }
                      .info div { margin: 5px 0; }
                      .label { font-weight: bold; color: #666; display: inline-block; width: 120px; }
                      .opsramp { background: #e3f2fd; padding: 10px; border-radius: 5px; margin-top: 15px; font-size: 12px; color: #1976d2; }
                  </style>
              </head>
              <body>
                  <div class="container">
                      <h1>🔌 Database Monitor</h1>
              <?php
              $db_host = "${aws_db_instance.postgres.endpoint}";
              $db_name = "demodb";
              $db_user = "demoadmin";
              $db_pass = "${var.db_password}";
              
              $host_clean = explode(':', $db_host)[0];
              $connected = false;
              $error = "";
              
              try {
                  $dsn = "pgsql:host=$host_clean;port=5432;dbname=$db_name";
                  $pdo = new PDO($dsn, $db_user, $db_pass, [PDO::ATTR_TIMEOUT => 5]);
                  $connected = true;
              } catch (PDOException $e) {
                  $error = $e->getMessage();
              }
              
              if ($connected) {
                  echo '<div class="status connected">';
                  echo '<div class="icon">✓</div>';
                  echo '<h2>Database Connected</h2>';
                  echo '<p>Application running normally</p>';
                  echo '</div>';
                  echo '<div class="info">';
                  echo '<div><span class="label">Database:</span> demodb</div>';
                  echo '<div><span class="label">Host:</span> ' . htmlspecialchars($host_clean) . '</div>';
                  echo '<div><span class="label">OS:</span> Ubuntu 22.04</div>';
                  echo '</div>';
              } else {
                  echo '<div class="status disconnected">';
                  echo '<div class="icon">✗</div>';
                  echo '<h2>Database Disconnected</h2>';
                  echo '<p>Cannot connect to database</p>';
                  echo '</div>';
                  echo '<div class="info">';
                  echo '<div><span class="label">Error:</span> ' . htmlspecialchars($error) . '</div>';
                  echo '</div>';
              }
              
              // Check OpsRamp status
              $opsramp_status = "Unknown";
              exec('systemctl is-active opsramp-agent 2>/dev/null', $output, $return_code);
              if ($return_code === 0) {
                  $opsramp_status = "Running ✓";
              }
              
              echo '<div class="opsramp">';
              echo '<strong>OpsRamp Agent:</strong> ' . $opsramp_status;
              echo '</div>';
              ?>
                      <p style="margin-top: 20px; color: #999; font-size: 14px;">
                          Last check: <?php echo date('H:i:s'); ?> | Auto-refresh: 10s
                      </p>
                  </div>
              </body>
              </html>
              PHP
              
              # Set permissions
              chown www-data:www-data /var/www/html/index.php
              chmod 644 /var/www/html/index.php
              
              # Remove Apache default page so our PHP page shows
              rm -f /var/www/html/index.html
              
              # Restart Apache
              systemctl restart apache2
              
              echo "=========================================="
              echo "Web Server Setup Complete"
              echo "=========================================="
              
              # Wait for web server to be ready
              sleep 5
              
              # ============================================
              # OPSRAMP AGENT INSTALLATION
              # ============================================
              
              echo ""
              echo "=========================================="
              echo "Starting OpsRamp Agent Installation"
              echo "=========================================="
              
              # Variables
              AGENT_URL="https://morpheus.init0xff.com/public-archives/download/Morpheus%20Software/opsramp-agent_20.0.0-1_amd64.deb"
              AGENT_FILE="/var/tmp/opsramp-agent_20.0.0-1_amd64.deb"
              OPSRAMP_KEY="dJ2xMZQwy9E6JpzuMybD3k4zdAXCTjpy"
              OPSRAMP_SECRET="xxxxxxx"
              OPSRAMP_SERVER="score.api.opsramp.com"
              OPSRAMP_INTEGRATION="xxxx"
              
              # Track status
              OVERALL_STATUS="SUCCESS"
              
              # Step 1: Download
              echo "Step 1: Downloading OpsRamp agent..."
              rm -f "$AGENT_FILE" 2>/dev/null
              if curl -k -fsSL -o "$AGENT_FILE" "$AGENT_URL" 2>/dev/null && [ -f "$AGENT_FILE" ]; then
                  echo "[✓] Package Download        : SUCCESS"
              else
                  echo "[✗] Package Download        : FAILED"
                  OVERALL_STATUS="FAILED"
              fi
              
              # Step 2: Install
              if [ "$OVERALL_STATUS" = "SUCCESS" ]; then
                  echo "Step 2: Installing OpsRamp agent..."
                  if dpkg -i "$AGENT_FILE" >/dev/null 2>&1; then
                      echo "[✓] Package Installation    : SUCCESS"
                  else
                      echo "[✗] Package Installation    : FAILED"
                      OVERALL_STATUS="FAILED"
                  fi
              fi
              
              # Step 3: Configure
              if [ "$OVERALL_STATUS" = "SUCCESS" ]; then
                  echo "Step 3: Configuring OpsRamp agent..."
                  if /opt/opsramp/agent/bin/configure \
                      -K "$OPSRAMP_KEY" \
                      -S "$OPSRAMP_SECRET" \
                      -s "$OPSRAMP_SERVER" \
                      -F "$OPSRAMP_INTEGRATION" \
                      -L true >/dev/null 2>&1; then
                      echo "[✓] Agent Configuration     : SUCCESS"
                  else
                      echo "[✗] Agent Configuration     : FAILED"
                      OVERALL_STATUS="FAILED"
                  fi
              fi
              
              # Step 4: Service Status
              if [ "$OVERALL_STATUS" = "SUCCESS" ]; then
                  echo "Step 4: Checking OpsRamp service..."
                  sleep 2
                  if systemctl is-active --quiet opsramp-agent; then
                      echo "[✓] Agent Service Status    : RUNNING"
                  else
                      echo "[✗] Agent Service Status    : NOT RUNNING"
                      OVERALL_STATUS="FAILED"
                  fi
              fi
              
              # Cleanup
              rm -f "$AGENT_FILE" 2>/dev/null
              
              # Final Summary
              echo ""
              echo "=========================================="
              if [ "$OVERALL_STATUS" = "SUCCESS" ]; then
                  echo "   OPSRAMP STATUS: ✓ SUCCESS"
                  echo "   Agent reporting to: $OPSRAMP_SERVER"
              else
                  echo "   OPSRAMP STATUS: ✗ FAILED"
              fi
              echo "=========================================="
              echo ""
              echo "User-Data Script Complete"
              echo "=========================================="
              
              EOF
  
  depends_on = [aws_db_instance.postgres]
  
  tags = {
    Name = "Demo-Web-Server"
  }
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "web_url" {
  value = "http://${aws_instance.web.public_ip}"
}

output "database_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "check_opsramp_logs" {
  value = "ssh ubuntu@${aws_instance.web.public_ip} 'sudo tail -100 /var/log/user-data.log'"
}

output "instructions" {
  value = <<-EOT
  
  ✓ Deployment Complete!
  
  1. Web URL: http://${aws_instance.web.public_ip}
  2. OpsRamp agent installed automatically
  3. Check logs: ssh ubuntu@${aws_instance.web.public_ip} 'sudo tail -100 /var/log/user-data.log'
  4. Page shows OpsRamp status at bottom
  
  Wait 2-3 minutes for OpsRamp to appear in portal.
  EOT
}
