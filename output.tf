
## outputs for nomad module

output "client_sg" {
  value = "${aws_security_group.nomad_client.id}"
}

output "server_sg" {
  value = "${aws_security_group.nomad_server.id}"
}

output "iam_instance_profile" {
  value = "${aws_iam_instance_profile.nomad.name}"
}

output "instances" {
  value = [  "${aws_instance.nomad.*.id}" ]
}
