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

resource "aws_service_discovery_http_namespace" "gearbox-namespace" {
  name        = "gearbox-namespace"
  description = "The namespace to use for Service Connect"
}

// Ferret Database

resource "aws_efs_file_system" "gearbox-datastore" {
  creation_token = "gearbox-datastore"
  tags = {
    name = "gearbox-datastore"
  }
}

resource "aws_ecs_task_definition" "ferretdb" {
  requires_compatibilities = ["FARGATE"]
  family                   = "ferretdb"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  cpu                      = 256
  memory                   = 512
  volume {
    name = aws_efs_file_system.gearbox-datastore.creation_token
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
          sourceVolume  = aws_efs_file_system.gearbox-datastore.creation_token
          containerPath = "/state"
          readOnly      = false
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "ferret" {
  name            = "ferret"
  cluster         = aws_ecs_cluster.gearbox.id
  task_definition = aws_ecs_task_definition.ferretdb.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.gearbox-namespace.arn
    service {
      port_name = jsondecode(aws_ecs_task_definition.ferretdb.container_definitions)[0].portMappings[0].name
    }
  }
}

// Gearbox Servers

resource "aws_vpc" "gearbox-vpc" {
  cidr_block = "10.0.0.0/16"
}

data "aws_subnets" "gearbox-subnets" {
  filter {
    name   = "vpc-id"
    values = [aws_vpc.gearbox-vpc.id]
  }
}

resource "aws_lb_target_group" "gearbox-instances" {
  name     = "gearbox-instances"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.gearbox-vpc.id
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

resource "aws_ecs_service" "gearbox" {
  name            = "gearbox"
  cluster         = aws_ecs_cluster.gearbox.id
  task_definition = aws_ecs_task_definition.gearbox.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.gearbox-namespace.arn
  }
  network_configuration {
    subnets         = data.aws_subnets.gearbox-subnets.ids
    security_groups = [aws_vpc.gearbox-vpc.default_security_group_id]
  }
}

resource "aws_lb" "gearbox-load-balancer" {
  name               = "gearbox"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_vpc.gearbox-vpc.default_security_group_id]
  subnets            = data.aws_subnets.gearbox-subnets.ids
}

resource "aws_lb_listener" "gearbox-https-listener" {
  load_balancer_arn = aws_lb.gearbox-load-balancer.arn
  port              = 443
  protocol          = "HTTPS"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gearbox-instances.arn
  }
}
