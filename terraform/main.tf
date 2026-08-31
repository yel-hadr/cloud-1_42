# Looked up rather than pasted. A hard-coded AMI ID is region-specific and
# goes stale the moment Canonical publishes a new image.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# --- Network -----------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "cloud1-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "cloud1-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "cloud1-igw" }
}

# A subnet is only "public" because of this route. Without the 0.0.0.0/0
# entry pointing at the gateway, the instance has a public IP it cannot use.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "cloud1-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security group ----------------------------------------------------

# The subject's "only 22, 80 and 443 from outside" requirement, enforced at
# the cloud edge. ufw inside the box enforces the same thing a second time,
# so a security-group mistake alone does not expose the host.
resource "aws_security_group" "web" {
  name        = "cloud1-web"
  description = "SSH, HTTP and HTTPS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "cloud1-web" }
}

# --- Instance ----------------------------------------------------------

resource "aws_key_pair" "deployer" {
  key_name   = "cloud1-key"
  public_key = file(var.public_key_path)
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.deployer.key_name

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    encrypted   = true
  }

  # Disable IMDSv1 - only session-based IMDSv2 is allowed. This prevents
  # SSRF-based metadata credential theft (CKV_AWS_79).
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = "cloud1" }
}

# A stop/start would otherwise hand back a different public IP, breaking the
# DNS records for youssefelhadraoui.tech. The EIP pins the address.
resource "aws_eip" "web" {
  domain   = "vpc"
  instance = aws_instance.web.id

  tags = { Name = "cloud1-eip" }

  depends_on = [aws_internet_gateway.main]
}
