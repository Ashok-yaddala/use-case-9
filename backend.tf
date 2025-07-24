terraform {
  backend "s3" {
    bucket  = "myaws-buckethcl-123"
    key     = "uc/terraform.tfstate"
    region  = "us-east-1"
  }
}