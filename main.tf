#
#  terraform module to establish a nomad cluster
#  running underneath a load balancer
#

locals {
  nomad_name_prefix        = "nomad-${var.id}-${var.env["full_name"]}"
  nomad_server_name_prefix = "nomad-server-${var.id}-${var.env["full_name"]}"
  nomad_client_name_prefix = "nomad-client-${var.env["full_name"]}"
  webui_ingress_cidrs      = "${concat(list(var.env["cidr"]), var.extra_cidrs)}"
  shortzones               = "${split(",", replace(join(",", data.aws_subnet.subnets.*.availability_zone), "-",""))}"

  client_tcp_ports   = [ "4646", "4647" ]
  client_udp_ports   = []
  server_tcp_ports   = [ "4646", "4647", "4648" ]
  server_udp_ports   = [ "4648" ]
}

data "aws_subnet" "subnets" {
  count = "${length(var.subnets)}"
  id    = "${element(var.subnets, count.index)}"
}


resource "aws_instance" "nomad" {
  count = "${var.node_count}"

  ami                  = "${data.aws_ami.nomad.id}"
  instance_type        = "${var.instance_type}"
  iam_instance_profile = "${aws_iam_instance_profile.nomad.name}"

  vpc_security_group_ids  = [ 
    "${aws_security_group.nomad_server.id}", 
    "${aws_security_group.nomad_client.id}",
    "${var.security_group_ids}"
  ]

  subnet_id               = "${element(var.subnets, count.index)}"
  key_name                = "${var.chef["infra_key"]}"
  disable_api_termination = "${var.disable_api_termination}"

  root_block_device {
    volume_type = "gp2"
    volume_size = "${var.volume_size}"
    delete_on_termination = "true"
  }

  provisioner "remote-exec" {
    connection {
      host         = "${self.private_ip}"
      user         = "ubuntu"
      private_key  = "${var.chef["private_key"]}"
      bastion_host = "${var.chef["bastion_host"]}"
      bastion_user = "${var.chef["bastion_user"]}"
      bastion_private_key = "${var.chef["bastion_private_key"]}"
    }
    inline = [
      "sudo mkdir -p /etc/chef/ohai/hints",
      "sudo touch /etc/chef/ohai/hints/ec2.json"
    ]
  }
  provisioner "chef" {
    connection {
      host         = "${self.private_ip}"
      user         = "ubuntu"
      private_key  = "${var.chef["private_key"]}"
      bastion_host = "${var.chef["bastion_host"]}"
      bastion_user = "${var.chef["bastion_user"]}"
      bastion_private_key = "${var.chef["bastion_private_key"]}"
    }

    attributes_json = <<EOF
    {
        "nomad-server": {
            "config": {
                "datacenter": "${var.datacenter}",
                "region":     "${var.region}",
                "id": "${var.id}"
            }
        }
    }
    EOF

    version     = "${var.chef["client_version"]}"
    environment = "${var.chef["environment"]}"
    run_list    = "${var.chef_runlist}"
    node_name   = "${local.nomad_server_name_prefix}-${format("%02d", count.index)}"
    server_url  = "${var.chef["server"]}"
    user_name   = "${var.chef["validation_client"]}"
    user_key    = "${var.chef["validation_key"]}"
  }

  tags {
    Name           = "${local.nomad_server_name_prefix}-${format("%02d", count.index)}"
    vpc            = "${var.env["vpc"]}"
    environment    = "${var.chef["environment"]}"
    env            = "${var.env["full_name"]}"
    provisioned_by = "terraform"
    configured_by  = "chef"
    chef_runlist   = "${join(",", var.chef_runlist)}"
    nomad_dc       = "${var.datacenter}"
    nomad_region   = "${var.region}"
  }

  lifecycle {
    ignore_changes = [
      "ami",
      "user_data"
    ]
  }
}


## security stuff

resource "aws_security_group" "nomad_client" {
  name        = "${local.nomad_client_name_prefix}"
  description = "Allow internode communication between nomad clients and servers"
  vpc_id      = "${var.env["vpc"]}"

  tags {
    Name           = "${local.nomad_client_name_prefix}"
    vpc            = "${var.env["vpc"]}"
    environment    = "${var.env["name"]}"
    provisioned_by = "terraform"
  }
}

resource "aws_security_group_rule" "nomad_client_tcp_ingress" {
  count = "${length(local.client_tcp_ports)}"

  type              = "ingress"
  from_port         = "${element(local.client_tcp_ports, count.index)}"
  to_port           = "${element(local.client_tcp_ports, count.index)}"
  protocol          = "tcp"
  self              = true
  security_group_id = "${aws_security_group.nomad_client.id}"
}

resource "aws_security_group_rule" "nomad_client_udp_ingress" {
  count = "${length(local.client_udp_ports)}"

  type              = "ingress"
  from_port         = "${element(local.client_udp_ports, count.index)}"
  to_port           = "${element(local.client_udp_ports, count.index)}"
  protocol          = "udp"
  self              = true
  security_group_id = "${aws_security_group.nomad_client.id}"
}


resource "aws_security_group_rule" "nomad_client_tcp_egress" {
  count = "${length(local.client_tcp_ports)}"

  type              = "egress"
  from_port         = "${element(local.client_tcp_ports, count.index)}"
  to_port           = "${element(local.client_tcp_ports, count.index)}"
  protocol          = "tcp"
  self              = true
  security_group_id = "${aws_security_group.nomad_client.id}"
}


resource "aws_security_group_rule" "nomad_udp_egress" {
  count = "${length(local.client_udp_ports)}"

  type              = "egress"
  from_port         = "${element(local.client_udp_ports, count.index)}"
  to_port           = "${element(local.client_udp_ports, count.index)}"
  protocol          = "udp"
  self              = true
  security_group_id = "${aws_security_group.nomad_client.id}"
}


resource "aws_security_group" "nomad_server" {
  name        = "${local.nomad_server_name_prefix}"
  description = "Allow internode communication among nomad servers"
  vpc_id      = "${var.env["vpc"]}"

  tags {
    Name           = "${local.nomad_server_name_prefix}"
    vpc            = "${var.env["vpc"]}"
    environment    = "${var.env["name"]}"
    provisioned_by = "terraform"
  }
}

resource "aws_security_group_rule" "nomad_server_tcp_ingress" {
  count = "${length(local.server_tcp_ports)}"

  type              = "ingress"
  from_port         = "${element(local.server_tcp_ports, count.index)}"
  to_port           = "${element(local.server_tcp_ports, count.index)}"
  protocol          = "tcp"
  self              = true
  security_group_id = "${aws_security_group.nomad_server.id}"
}

resource "aws_security_group_rule" "nomad_server_tcp_egress" {
  count = "${length(local.server_tcp_ports)}"

  type              = "egress"
  from_port         = "${element(local.server_tcp_ports, count.index)}"
  to_port           = "${element(local.server_tcp_ports, count.index)}"
  protocol          = "tcp"
  self              = true
  security_group_id = "${aws_security_group.nomad_server.id}"
}

resource "aws_security_group_rule" "nomad_server_udp_ingress" {
  count = "${length(local.server_udp_ports)}"

  type              = "ingress"
  from_port         = "${element(local.server_udp_ports, count.index)}"
  to_port           = "${element(local.server_udp_ports, count.index)}"
  protocol          = "udp"
  self              = true
  security_group_id = "${aws_security_group.nomad_server.id}"
}

resource "aws_security_group_rule" "nomad_server_udp_egress" {
  count = "${length(local.server_udp_ports)}"

  type              = "egress"
  from_port         = "${element(local.server_udp_ports, count.index)}"
  to_port           = "${element(local.server_udp_ports, count.index)}"
  protocol          = "udp"
  self              = true
  security_group_id = "${aws_security_group.nomad_server.id}"
}


resource "aws_security_group_rule" "web_lb_ingress" {
  count = "${var.web_lb_sg == "" ? 0 : 1 }"

  security_group_id = "${aws_security_group.nomad_server.id}"
  type              = "ingress"
  from_port         = "8080"
  to_port           = "8080"
  protocol          = "tcp"

  source_security_group_id = "${var.web_lb_sg}"
}

resource "aws_security_group_rule" "web_lb_ingress_80" {
  count = "${var.web_lb_sg == "" ? 0 : 1 }"

  security_group_id = "${aws_security_group.nomad_server.id}"
  type              = "ingress"
  from_port         = "80"
  to_port           = "80"
  protocol          = "tcp"

  source_security_group_id = "${var.web_lb_sg}"
}

resource "aws_security_group_rule" "web_lb_ingress_alt" {
  count = "${var.web_lb_sg == "" ? 0 : 1 }"

  security_group_id = "${aws_security_group.nomad_server.id}"
  type              = "ingress"
  from_port         = "8081"
  to_port           = "8081"
  protocol          = "tcp"

  source_security_group_id = "${var.web_lb_sg}"
}


# ami lookup
data "aws_ami" "nomad" {
  most_recent = true

  filter {
    name   = "root-device-type"
    values = [ "ebs"]
  }

  name_regex = "${var.ami_name}"
  owners     = [ "${var.ami_owner}" ]
}

# iam profile stuff

resource "aws_iam_instance_profile" "nomad" {
  name = "${local.nomad_name_prefix}-${var.env["shortregion"]}"
  role = "${aws_iam_role.nomad.name}"
}

resource "aws_iam_role" "nomad" {
  name               = "${local.nomad_name_prefix}-${var.env["shortregion"]}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "nomad" {
  name   = "${local.nomad_name_prefix}-${var.env["shortregion"]}"
  policy = "${var.iam_policy}"
}

resource "aws_iam_policy_attachment" "nomad" {
  name       = "${local.nomad_name_prefix}-${var.env["shortregion"]}"
  roles      = [ "${aws_iam_role.nomad.name}" ]
  policy_arn = "${aws_iam_policy.nomad.arn}"
}
