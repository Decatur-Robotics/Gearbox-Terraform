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

data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
}

resource "aws_ecs_cluster" "gearbox" {
  name = "gearbox"
}

resource "aws_ecs_task_definition" "gearbox" {
  family = "service"
  container_definitions = jsonencode([
    {
      name             = "gearbox"
      image            = "ghcr.io/decatur-robotics/gearbox:latest"
      cpu              = 256
      memory           = 512
      essential        = true
      executionRoleArn = data.aws_iam_role.ecs_task_execution_role.arn
      task_role_arn = data.aws_iam_role.ecs_task_execution_role.arn
      portMappings = [
        {
          name          = "http"
          containerPort = 80
          hostPost      = 80
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environmentFiles = [
        {
          value = "arn:aws:s3:::gearbox-test-env/.env"
          type  = "s3"
        }
      ]
    }
  ])
}