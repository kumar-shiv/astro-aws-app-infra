resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? length(var.public_subnet_ids) : 0
  domain = "vpc"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-nat-eip-${count.index + 1}"
    }
  )

  depends_on = []
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? length(var.public_subnet_ids) : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = var.public_subnet_ids[count.index]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-nat-gw-${count.index + 1}"
    }
  )

  depends_on = [aws_eip.nat]
}
