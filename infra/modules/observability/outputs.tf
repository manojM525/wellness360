output "workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "workspace_arn" {
  value = aws_prometheus_workspace.this.arn
}

# The ADOT sidecar sends metrics here — note the "api/v1/remote_write" suffix
# is required, AMP's own endpoint attribute is just the base URL.
output "remote_write_endpoint" {
  value = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}
