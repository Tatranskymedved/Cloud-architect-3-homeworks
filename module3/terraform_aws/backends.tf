# ── IAM: ECS Task Execution Role ──────────────────────────────────────────────
# Assumed by the ECS agent to pull images and write logs to CloudWatch.
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── CloudWatch Log Groups ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "api_v1" {
  name              = "/ecs/${var.project_name}/api-v1"
  retention_in_days = 7

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "api_v2" {
  name              = "/ecs/${var.project_name}/api-v2"
  retention_in_days = 7

  tags = var.tags
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = var.tags
}

# ── ECS Task Definition: API v1 ───────────────────────────────────────────────
resource "aws_ecs_task_definition" "api_v1" {
  family                   = "${var.project_name}-api-v1"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "api-v1"
    image     = var.api_image_v1
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api_v1.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api-v1"
      }
    }

    environment = []
  }])

  tags = var.tags
}

# ── ECS Task Definition: API v2 ───────────────────────────────────────────────
resource "aws_ecs_task_definition" "api_v2" {
  family                   = "${var.project_name}-api-v2"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "api-v2"
    image     = var.api_image_v2
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api_v2.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api-v2"
      }
    }

    environment = []
  }])

  tags = var.tags
}

# ── ECS Service: API v1 ───────────────────────────────────────────────────────
# assign_public_ip = false — tasks are in private subnets; image pull via NAT GW.
# ECS automatically registers/deregisters task IPs in the ALB target group.
resource "aws_ecs_service" "api_v1" {
  name            = "${var.project_name}-svc-api-v1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_v1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.v1.arn
    container_name   = "api-v1"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution,
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── ECS Service: API v2 ───────────────────────────────────────────────────────
resource "aws_ecs_service" "api_v2" {
  name            = "${var.project_name}-svc-api-v2"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api_v2.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.v2.arn
    container_name   = "api-v2"
    container_port   = 8080
  }

  depends_on = [
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.ecs_task_execution,
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count]
  }
}
