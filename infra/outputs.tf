# Output the website URL and function URL
output "website_url" {
  value = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}

output "function_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}