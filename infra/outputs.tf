# Output the website URL and function URL
output "website_url" {
  value = "https://${aws_cloudfront_distribution.site_cdn.domain_name}"
}

output "function_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}