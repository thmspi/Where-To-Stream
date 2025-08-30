variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
}
variable "project" {
  type    = string
  default = "who-streams-it"
}
variable "tmdb_key" {
  type      = string
  sensitive = true
}
variable "lambda_env" {
  type    = map(string)
  default = {}
}
