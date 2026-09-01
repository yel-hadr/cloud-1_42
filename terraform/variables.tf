variable "region" {
  description = "AWS region. eu-west-3 (Paris) is where the hand-built instance lived."
  type        = string
  default     = "eu-west-3"
}

# Kept as a variable rather than hard-coded so the size stays visible. The
# subject is explicit that oversizing burns credits; t3.micro is the free
# tier and comfortably runs four containers once the swapfile is in place.
variable "instance_type" {
  description = "EC2 instance size."
  type        = string
  default     = "t3.micro"
}

variable "public_key_path" {
  description = <<-EOT
    Public half of the SSH key Ansible connects with. Derive it from the
    private key the repo already uses:
      ssh-keygen -y -f server_key.pem > server_key.pub
  EOT
  type        = string
  default     = "../server_key.pub"
}

# Port 22 must stay reachable for the evaluation, so this defaults to open.
# The compensating controls are in the security role: key-only auth (no
# passwords), no root login, and fail2ban. Narrow it to "x.x.x.x/32" while
# developing if you prefer.
variable "ssh_allowed_cidr" {
  description = "CIDR permitted to reach port 22."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  description = "CIDR for the project VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}
