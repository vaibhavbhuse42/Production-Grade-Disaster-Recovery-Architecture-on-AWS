
# PROVIDERS

provider "aws" {
  region = "ap-south-1"
}

provider "aws" {
  alias  = "dr"
  region = "ap-southeast-1"
}

# VARIABLES

variable "db_username" {
  default = "admin"
}

variable "db_password" {
  default = "Password123!"
}

variable "domain_name" {
  default = "vaibhavbhuse.com"
}

# PRIMARY VPC

resource "aws_vpc" "primary_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = { Name = "Primary-VPC" }
}

resource "aws_subnet" "primary_subnet" {
  vpc_id            = aws_vpc.primary_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-south-1a"
  map_public_ip_on_launch = true
}

# DR VPC

resource "aws_vpc" "dr_vpc" {
  provider = aws.dr
  cidr_block = "10.1.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = { Name = "DR-VPC" }
}

resource "aws_subnet" "dr_subnet" {
  provider          = aws.dr
  vpc_id            = aws_vpc.dr_vpc.id
  cidr_block        = "10.1.1.0/24"
  availability_zone = "ap-southeast-1a"
  map_public_ip_on_launch = true
}

# S3 PRIMARY

resource "aws_s3_bucket" "primary_bucket" {
  bucket = "vaibhav-healthcare-primary-bucket"
}

resource "aws_s3_bucket_versioning" "primary_versioning" {
  bucket = aws_s3_bucket.primary_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 DR

resource "aws_s3_bucket" "dr_bucket" {
  provider = aws.dr
  bucket   = "vaibhav-healthcare-dr-bucket"
}

resource "aws_s3_bucket_versioning" "dr_versioning" {
  provider = aws.dr
  bucket = aws_s3_bucket.dr_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM ROLE FOR S3 REPLICATION

resource "aws_iam_role" "replication_role" {
  name = "s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "replication_policy" {
  role       = aws_iam_role.replication_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# S3 REPLICATION CONFIG

resource "aws_s3_bucket_replication_configuration" "replication" {
  depends_on = [
    aws_s3_bucket_versioning.primary_versioning,
    aws_s3_bucket_versioning.dr_versioning
  ]

  role   = aws_iam_role.replication_role.arn
  bucket = aws_s3_bucket.primary_bucket.id

  rule {
    id     = "replication-rule"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.dr_bucket.arn
      storage_class = "STANDARD"
    }
  }
}

# RDS PRIMARY

resource "aws_db_instance" "primary_db" {
  allocated_storage    = 20
  engine               = "mysql"
  instance_class       = "db.t3.micro"
  username             = var.db_username
  password             = var.db_password
  skip_final_snapshot  = true
  publicly_accessible  = true
}

# RDS READ REPLICA (DR REGION)

resource "aws_db_instance" "dr_replica" {
  provider               = aws.dr
  replicate_source_db    = aws_db_instance.primary_db.arn
  instance_class         = "db.t3.micro"
  publicly_accessible    = true
  skip_final_snapshot    = true
}

# EC2 PRIMARY

resource "aws_instance" "primary_ec2" {
  ami           = "ami-051a31ab2f4d498f5"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.primary_subnet.id

  tags = { Name = "Primary-App-Server" }
}

# EC2 DR

resource "aws_instance" "dr_ec2" {
  provider      = aws.dr
  ami           = "ami-0ac0e4288aa341886"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.dr_subnet.id

  tags = { Name = "DR-App-Server" }
}

# ROUTE 53 HEALTH CHECK

resource "aws_route53_health_check" "primary_health" {
  fqdn              = aws_instance.primary_ec2.public_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30
}

# ROUTE 53 FAILOVER RECORD

resource "aws_route53_record" "primary_record" {
  zone_id = "Z06455331I9JIJT7KD549"
  name    = var.domain_name
  type    = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier = "primary"
  health_check_id = aws_route53_health_check.primary_health.id

  alias {
    name                   = aws_instance.primary_ec2.public_dns
    zone_id                = aws_instance.primary_ec2.availability_zone
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "secondary_record" {
  provider = aws.dr
  zone_id = "Z06455331I9JIJT7KD549"
  name    = var.domain_name
  type    = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "secondary"

  alias {
    name                   = aws_instance.dr_ec2.public_dns
    zone_id                = aws_instance.dr_ec2.availability_zone
    evaluate_target_health = true
  }
}