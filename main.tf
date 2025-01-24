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

resource "aws_efs_file_system" "gearbox-datastore" {
  creation_token = "gearbox-datastore"
  tags = {
    name = "gearbox-datastore"
  }
}

// Be sure to jsonencode() the container_definitions! If you get an error about "string required," you forgot to do this.

resource "aws_ecs_task_definition" "gearbox" {
  requires_compatibilities = ["FARGATE"]
  family                   = "gearbox"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  cpu                      = 256
  memory                   = 512
  container_definitions = jsonencode([
    {
      name      = "gearbox"
      image     = "ghcr.io/decatur-robotics/gearbox:latest"
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
      environmentFiles = [
        {
          value = "arn:aws:s3:::gearbox-test-env/.env"
          type  = "s3"
        }
      ]
    }
  ])
}

resource "aws_ecs_task_definition" "ferretdb" {
  requires_compatibilities = ["FARGATE"]
  family                   = "ferretdb"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  cpu                      = 256
  memory                   = 512
  volume {
    name = "gearbox-datastore"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.gearbox-datastore.id
    }
  }
  container_definitions = jsonencode([
    {
      name      = "ferretdb"
      image     = "ghcr.io/ferretdb/ferretdb-dev"
      essential = true
      portMappings = [
        {
          name          = "mongo"
          containerPort = 27017
          hostPort      = 27017
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "FERRETDB_HANDLER"
          value = "sqlite"
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "gearbox-datastore"
          containerPath = "/state"
          readOnly      = false
        }
      ]
    }
  ])
}