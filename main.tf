terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.10.0"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_ecs_cluster" "gearbox" {
  name = "gearbox"
}

resource "aws_ecs_task_definition" "gearbox" {
  family = "service"
  container_definitions = jsonencode([
    {
      name      = "gearbox"
      image     = "ghcr.io/decatur-robotics/gearbox:latest"
      cpu       = 0
      essential = true
      portMappings = [
        {
          name          = "http"
          containerPort = 80
          hostPost      = 80
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        {
          value = "arn:aws:s3:::gearbox-test-env/.env"
          type  = "s3"
        }
      ]
    }
  ])
}