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

resource "aws_vpc" "ferret-vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "ferret-subnet" {
  vpc_id     = aws_vpc.ferret-vpc.id
  cidr_block = "10.0.0.0/16"
}

resource "aws_security_group_rule" "allow-27017-ingress" {
  type              = "ingress"
  from_port         = 27017
  to_port           = 27017
  protocol          = "tcp"
  security_group_id = aws_security_group.allow-27017-ingress-and-egress.id
  cidr_blocks       = [aws_vpc.ferret-vpc.cidr_block]
}

resource "aws_security_group_rule" "allow-27017-egress" {
  type              = "egress"
  from_port         = 27017
  to_port           = 27017
  protocol          = "tcp"
  security_group_id = aws_security_group.allow-27017-ingress-and-egress.id
  cidr_blocks       = [aws_vpc.ferret-vpc.cidr_block]
}

resource "aws_security_group" "allow-27017-ingress-and-egress" {
  name   = "allow-http"
  vpc_id = aws_vpc.ferret-vpc.id
}

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
      client_alias {
        port = 27017
      }
      port_name = jsondecode(aws_ecs_task_definition.ferretdb.container_definitions)[0].portMappings[0].name
    }
  }
  network_configuration {
    subnets         = [aws_subnet.ferret-subnet.id]
    security_groups = [aws_security_group.allow-27017-ingress-and-egress.id]
  }
}

// Gearbox Servers

resource "aws_vpc" "gearbox-vpc" {
  cidr_block = "172.31.0.0/16"
}

resource "aws_security_group_rule" "allow-http-ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.allow-http-ingress-and-all-egress.id
  cidr_blocks       = [aws_vpc.gearbox-vpc.cidr_block]
}

resource "aws_security_group_rule" "allow-all-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = aws_security_group.allow-http-ingress-and-all-egress.id
  cidr_blocks       = [aws_vpc.gearbox-vpc.cidr_block]
}

resource "aws_security_group" "allow-http-ingress-and-all-egress" {
  name   = "allow-http"
  vpc_id = aws_vpc.gearbox-vpc.id
}

variable "gearbox-subnet-availability-zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

resource "aws_subnet" "gearbox-subnets" {
  count             = length(var.gearbox-subnet-availability-zones)
  vpc_id            = aws_vpc.gearbox-vpc.id
  cidr_block        = "172.31.${count.index * 16}.0/20"
  availability_zone = var.gearbox-subnet-availability-zones[count.index]
}

resource "aws_internet_gateway" "gearbox-internet-gateway" {
  vpc_id = aws_vpc.gearbox-vpc.id
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
    subnets         = aws_subnet.gearbox-subnets[*].id
    security_groups = [aws_security_group.allow-http-ingress-and-all-egress.id]
  }
}

resource "aws_lb" "gearbox-load-balancer" {
  name               = "gearbox"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_vpc.gearbox-vpc.default_security_group_id]
  subnets            = aws_subnet.gearbox-subnets[*].id
}

resource "aws_lb_listener" "gearbox-https-listener" {
  load_balancer_arn = aws_lb.gearbox-load-balancer.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gearbox-instances.arn
  }
}
