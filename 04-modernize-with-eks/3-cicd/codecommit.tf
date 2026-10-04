resource "aws_codecommit_repository" "backend" {
  repository_name = var.backend_repository_name
  description     = "CodeCommit repository for backend service"

  tags = {
    Name = var.backend_repository_name
  }
}

resource "aws_codecommit_repository" "frontend" {
  repository_name = var.frontend_repository_name
  description     = "CodeCommit repository for frontend service"

  tags = {
    Name = var.frontend_repository_name
  }
}

