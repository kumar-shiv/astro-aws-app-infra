terraform {
  backend "s3" {
    bucket = "astro-app-terraform-state"
    key    = "terraform.tfstate"
    region = "us-east-1"
    # No DynamoDB lock table — single developer, no concurrent applies needed
  }
}
