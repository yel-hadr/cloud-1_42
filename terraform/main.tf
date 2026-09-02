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

  # data.aws_ami.ubuntu re-resolves to whatever Canonical published most
  # recently, and `ami` forces replacement. Without this, a routine `make up`
  # taken after a new image lands would destroy the running box - and the
  # WordPress database on its root volume - just to rebuild it on a newer
  # base. Rebuilding on a newer image stays possible, but only deliberately,
  # via `make down` then `make up`.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "cloud1" }
}

# A stop/start would otherwise hand back a different public IP, breaking the
# DNS records for youssefelhadraoui.tech. The EIP pins the address.
#
# The *allocation* is deliberately not a resource here. `make down` destroys
# this whole state - instance, subnet, VPC - and an EIP owned by it would be
# released along with them, handing the address back to AWS. The next
# `make up` would then come back on a different one and every A record for
# the domain would have to be re-pointed by hand. Looking it up instead means
# teardown only ever destroys the association below, and the address outlives
# any number of down/up cycles.
#
# Allocated once, out of band. If this data source cannot find it, create it:
#
#   aws ec2 allocate-address --domain vpc --region eu-west-3 \
#     --tag-specifications \
#     'ResourceType=elastic-ip,Tags=[{Key=Name,Value=cloud1-eip}]'
#
# and delete it the same way (`release-address`) on the day the project is
# retired - AWS bills an allocated IPv4 address whether it is attached or not.
#
# The tag has to be unique in the region: a second allocation carrying
# Name=cloud1-eip makes this lookup ambiguous and Terraform refuses to plan
# with "multiple EC2 EIPs matched". `aws ec2 describe-addresses --region
# eu-west-3 --filters Name=tag:Name,Values=cloud1-eip` should return exactly
# one address; release the spare if it returns more.
data "aws_eip" "web" {
  tags = { Name = "cloud1-eip" }
}

# Attaching is still Terraform's job, and this is what `make down` removes.
resource "aws_eip_association" "web" {
  instance_id   = aws_instance.web.id
  allocation_id = data.aws_eip.web.id

  depends_on = [aws_internet_gateway.main]
}
