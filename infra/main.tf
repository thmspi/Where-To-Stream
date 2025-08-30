terraform {
  backend "remote" {
    organization = "Who-Stream-It"
    workspaces {
      name = "dev"
    }
  }
} 