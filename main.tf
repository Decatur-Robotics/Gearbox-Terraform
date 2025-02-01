terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.10.0"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.region
}

data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
}

resource "aws_ecs_cluster" "gearbox" {
  name = "gearbox"
}

resource "aws_service_discovery_http_namespace" "gearbox-namespace" {
  name        = "gearbox"
  description = "The namespace to use for Service Connect"
}

resource "aws_cloudwatch_log_group" "gearbox-logs" {
  name = "gearbox-logs"
}

// Network Config

resource "aws_vpc" "gearbox-vpc" {
  cidr_block           = "40.26.0.0/16"
  enable_dns_hostnames = true // Necessary to avoid "cannot resolve" errors with EFS
}

resource "aws_security_group_rule" "gearbox-allow-http-ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = aws_security_group.gearbox-security-group.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "ferret-allow-mongo-ingress" {
  type              = "ingress"
  from_port         = 27017
  to_port           = 27017
  protocol          = "tcp"
  security_group_id = aws_security_group.gearbox-security-group.id
  cidr_blocks       = [aws_vpc.gearbox-vpc.cidr_block]
}

// For the EFS mount target
resource "aws_security_group_rule" "ferret-allow-efs-ingress" {
  type              = "ingress"
  from_port         = 2049
  to_port           = 2049
  protocol          = "-1"
  security_group_id = aws_security_group.gearbox-security-group.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "gearbox-allow-all-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = aws_security_group.gearbox-security-group.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group" "gearbox-security-group" {
  name   = "gearbox-security-group"
  vpc_id = aws_vpc.gearbox-vpc.id
}

// Ferret Database

resource "aws_efs_file_system" "ferret-datastore" {
  creation_token = "ferret-datastore"
  tags = {
    name = "ferret-datastore"
  }
}

resource "aws_efs_mount_target" "ferret-datastore-mount-target" {
  file_system_id  = aws_efs_file_system.ferret-datastore.id
  subnet_id       = aws_subnet.gearbox-subnets[0].id
  security_groups = [aws_security_group.gearbox-security-group.id]
}

resource "aws_cloudwatch_log_stream" "ferret-log-stream" {
  name           = "ferret-log-stream"
  log_group_name = aws_cloudwatch_log_group.gearbox-logs.name
}

resource "aws_ecs_task_definition" "ferretdb" {
  requires_compatibilities = ["FARGATE"]
  family                   = "ferretdb"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  cpu                      = 256
  memory                   = 512
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume {
    name = aws_efs_file_system.ferret-datastore.creation_token
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.ferret-datastore.id
    }
  }
  container_definitions = jsonencode([
    {
      name      = "ferretdb"
      image     = "ghcr.io/ferretdb/ferretdb-dev:1.24.0" // Later versions give authentication errors
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
        },
        # {
        #   name = "FERRETDB_AUTH"
        #   value = "false"
        # }
      ]
      mountPoints = [
        {
          sourceVolume  = aws_efs_file_system.ferret-datastore.creation_token
          containerPath = "/state"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gearbox-logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = aws_cloudwatch_log_stream.ferret-log-stream.name
        }
      }
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
    subnets          = [aws_subnet.gearbox-subnets[0].id]
    security_groups  = [aws_security_group.gearbox-security-group.id]
    assign_public_ip = true
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

// Gearbox Servers

variable "gearbox-subnet-availability-zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

resource "aws_subnet" "gearbox-subnets" {
  count             = length(var.gearbox-subnet-availability-zones)
  vpc_id            = aws_vpc.gearbox-vpc.id
  cidr_block        = "40.26.${(count.index + 1) * 16}.0/20"
  availability_zone = var.gearbox-subnet-availability-zones[count.index]
}

resource "aws_internet_gateway" "gearbox-internet-gateway" {
  vpc_id = aws_vpc.gearbox-vpc.id
}

resource "aws_route_table" "gearbox-route-table" {
  vpc_id = aws_vpc.gearbox-vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gearbox-internet-gateway.id
  }
  route {
    cidr_block = aws_vpc.gearbox-vpc.cidr_block
    gateway_id = "local"
  }
}

resource "aws_route_table_association" "gearbox-route-table-association" {
  count          = length(var.gearbox-subnet-availability-zones)
  subnet_id      = aws_subnet.gearbox-subnets[count.index].id
  route_table_id = aws_route_table.gearbox-route-table.id
}

data "aws_iam_role" "s3-access-role" {
  name = "s3-full-access-role"
}

resource "aws_cloudwatch_log_stream" "gearbox-log-stream" {
  name           = "gearbox-log-stream"
  log_group_name = aws_cloudwatch_log_group.gearbox-logs.name
}

// Be sure to jsonencode() the container_definitions! If you get an error about "string required," you forgot to do this.
resource "aws_ecs_task_definition" "gearbox" {
  requires_compatibilities = ["FARGATE"]
  family                   = "gearbox"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = data.aws_iam_role.s3-access-role.arn
  cpu                      = 256
  memory                   = 512
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
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
          value = "arn:aws:s3:::4026-gearbox-test-envs/.env"
          type  = "s3"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gearbox-logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = aws_cloudwatch_log_stream.gearbox-log-stream.name
        }
      }
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
    subnets          = aws_subnet.gearbox-subnets[*].id
    security_groups  = [aws_security_group.gearbox-security-group.id]
    assign_public_ip = true
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.gearbox-instances.arn
    container_name   = jsondecode(aws_ecs_task_definition.gearbox.container_definitions)[0].name
    container_port   = 80
  }
}

resource "aws_appautoscaling_target" "ecs_target" {
  max_capacity       = 5
  min_capacity       = 1
  resource_id        = aws_ecs_service.gearbox.resource_id
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy" {
  name               = "scale-down"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 75
    scale_in_cooldown = 30
    scale_out_cooldown = 30
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

data "aws_acm_certificate" "gearbox-certificate" {
  domain = "*.4026.org"
}

resource "aws_security_group" "load-balancer-security-group" {
  name   = "load-balancer-security-group"
  vpc_id = aws_vpc.gearbox-vpc.id
}

resource "aws_security_group_rule" "load-balancer-allow-https-ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.load-balancer-security-group.id
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "load-balancer-allow-all-egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  security_group_id = aws_security_group.load-balancer-security-group.id
  cidr_blocks       = [aws_vpc.gearbox-vpc.cidr_block]
}

resource "aws_lb_target_group" "gearbox-instances" {
  name        = "gearbox-instances"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.gearbox-vpc.id
  target_type = "ip"
}

resource "aws_lb" "gearbox-load-balancer" {
  name               = "gearbox"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load-balancer-security-group.id]
  subnets            = aws_subnet.gearbox-subnets[*].id
}

resource "aws_lb_listener" "gearbox-https-listener" {
  load_balancer_arn = aws_lb.gearbox-load-balancer.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = data.aws_acm_certificate.gearbox-certificate.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gearbox-instances.arn
  }
}
