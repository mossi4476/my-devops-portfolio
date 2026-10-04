data "aws_iam_policy_document" "ecs_instance_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com",
        "ecs.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name               = "ecs-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_role_policy.json
}

resource "aws_iam_role_policy_attachment" "ecs_instance_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ])

  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-role"
  role = aws_iam_role.ecs_instance_role.id
}


