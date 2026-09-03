variable "region" {
  description = "AWS region. Must match the region of ../variables.tf - an Elastic IP cannot cross regions."
  type        = string
  default     = "eu-west-3"
}
