resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

locals {
  name = "datadog-event-notification-${random_string.suffix.result}"
  text_json = jsonencode({
    "field1" : "1",
    "field2" : "abc"
  })
  event_payload = {
    "alert_type" : "info",
    "priority" : "normal",
    "service" : "stepfunctions",
    "source_type_name" : "stepfunctions",
    "text" : local.text_json,
    "title" : "ECS Patching Status",
    "tags" : [
      "ecs_patching:initiated"
    ]
  }
}

resource "aws_cloudwatch_event_connection" "datadog" {
  name               = local.name
  authorization_type = "API_KEY"


  auth_parameters {
    api_key {
      key   = "DD-API-KEY"
      value = var.datadog_api_key
    }
  }
}

resource "aws_iam_role" "datadog" {
  name = local.name
  path = "/service-role/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "datadog" {
  name = local.name
  role = aws_iam_role.datadog.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "events:PutEvents",
          "events:RetrieveConnectionCredentials"
        ],
        "Resource" : aws_cloudwatch_event_connection.datadog.arn
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "states:InvokeHTTPEndpoint"
        ],
        "Resource" : aws_sfn_state_machine.datadog.arn
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ],
        "Resource" : aws_cloudwatch_event_connection.datadog.secret_arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "datadog" {
  name     = local.name
  role_arn = aws_iam_role.datadog.arn

  definition = jsonencode({
    "Comment" : "A state machine that sends events to Datadog using HTTP Task",
    "StartAt" : "SendEvent",
    "States" : {
      "Fail" : {
        "Type" : "Fail"
      },
      "SendEvent" : {
        "Catch" : [
          {
            "Comment" : "Handle all non-200 errors",
            "ErrorEquals" : [
              "States.Http.StatusCode.404",
              "States.Http.StatusCode.400",
              "States.Http.StatusCode.401",
              "States.Http.StatusCode.409",
              "States.Http.StatusCode.500"
            ],
            "Next" : "Fail"
          }
        ],
        "Next" : "Success",
        "Parameters" : {
          "ApiEndpoint" : "https://api.datadoghq.com/api/v1/events",
          "Authentication" : {
            "ConnectionArn" : aws_cloudwatch_event_connection.datadog.arn
          },
          "Headers" : {
            "Content-Type" : "application/json"
          },
          "Method" : "POST",
          "RequestBody" : local.event_payload
        },
        "Resource" : "arn:aws:states:::http:invoke",
        "Retry" : [
          {
            "BackoffRate" : 2,
            "ErrorEquals" : [
              "States.Http.StatusCode.429",
              "States.Http.StatusCode.503",
              "States.Http.StatusCode.504",
              "States.Http.StatusCode.502"
            ],
            "IntervalSeconds" : 1,
            "JitterStrategy" : "FULL",
            "MaxAttempts" : 3
          }
        ],
        "Type" : "Task"
      },
      "Success" : {
        "Type" : "Succeed"
      }
    }
    }
  )
}
