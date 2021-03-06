# Create the lambda role (using lambdarole.json file)
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

resource "aws_iam_role" "ebs_bckup-role-lambdarole" {
  name               = "${var.stack_prefix}-role-lambdarole-${var.unique_name}"
  assume_role_policy = "${file("${path.module}/files/lambdarole.json")}"
}

# Apply the Policy Document we just created
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

resource "aws_iam_role_policy" "ebs_bckup-role-lambdapolicy" {
  name = "${var.stack_prefix}-role-lambdapolicy-${var.unique_name}"
  role = "${aws_iam_role.ebs_bckup-role-lambdarole.id}"
  policy = "${file("${path.module}/files/lambdapolicy.json")}"
}

# Output the ARN of the lambda role
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Render vars.ini for Lambda function

data "template_file" "vars" {
  template = "${file("${path.module}/files/vars.ini.template")}"
  vars {
    EC2_INSTANCE_TAG_KEY               = "${var.EC2_INSTANCE_TAG_KEY}"
    EC2_INSTANCE_TAG_VALUE             = "${var.EC2_INSTANCE_TAG_VALUE}"
    RETENTION_DAYS                     = "${var.RETENTION_DAYS}"
    REGIONS                            = "${join(",", var.regions)}"
  }
}

resource "null_resource" "trigger" {
  triggers {
    SCRIPT_SHA                     = "${sha256(file("${path.module}\\ebs_bckup\\ebs_bckup.py"))}"
    TEMPLATE                       = "${data.template_file.vars.rendered}"
  }
}

resource "null_resource" "mkdir_lambda" {
  depends_on = ["null_resource.trigger"]
  provisioner "local-exec" {
    command = "if not exist ${path.module}\\lambda mkdir ${path.module}\\lambda"
  }
}

resource "null_resource" "mkdir_tmp" {
  depends_on = ["null_resource.trigger"]
  provisioner "local-exec" {
    command = "if not exist ${path.module}\\tmp mkdir ${path.module}\\tmp"
  }
}

resource "null_resource" "mv_python_script" {
  depends_on  = ["null_resource.mkdir_lambda", "null_resource.mkdir_tmp"]
  provisioner "local-exec" {
    command = "copy ${path.module}\\ebs_bckup\\ebs_bckup.py ${path.module}\\tmp\\ebs_bckup.py"
  }
}

resource "local_file" "buildlambdazip" {
  depends_on  = ["null_resource.mv_python_script"]
  content  = "${data.template_file.vars.rendered}"
  filename = "${path.module}/tmp/vars.ini"
}

data "null_data_source" "check_script_change_trigger" {
  inputs = {
    trigger = "${null_resource.trigger.id}"
    source_dir = "${path.module}\\tmp"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${data.null_data_source.check_script_change_trigger.outputs["source_dir"]}"
  output_path = "${path.module}\\lambda\\${var.stack_prefix}-${var.unique_name}.zip"
}

# Create lambda function
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

resource "aws_lambda_function" "ebs_bckup_lambda" {
  function_name     = "${var.stack_prefix}_lambda_${var.unique_name}"
  filename          = "${path.module}/lambda/${var.stack_prefix}-${var.unique_name}.zip"
  source_code_hash  = "${data.archive_file.lambda_zip.output_base64sha256}"
  role              = "${aws_iam_role.ebs_bckup-role-lambdarole.arn}"
  runtime           = "python2.7"
  handler           = "ebs_bckup.lambda_handler"
  timeout           = "60"
  publish           = true
  depends_on        = ["data.archive_file.lambda_zip"]
}

# Run the function with CloudWatch Event cronlike scheduler

resource "aws_cloudwatch_event_rule" "ebs_bckup_timer" {
  name = "${var.stack_prefix}_ebs_bckup_event_${var.unique_name}"
  description = "Cronlike scheduled Cloudwatch Event for creating and deleting EBS Snapshots"
  schedule_expression = "cron(${var.cron_expression})"
}

# Assign event to Lambda target
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

resource "aws_cloudwatch_event_target" "run_ebs_bckup_lambda" {
  rule = "${aws_cloudwatch_event_rule.ebs_bckup_timer.name}"
  target_id = "${aws_lambda_function.ebs_bckup_lambda.id}"
  arn = "${aws_lambda_function.ebs_bckup_lambda.arn}"
}

# Allow lambda to be called from cloudwatch
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

resource "aws_lambda_permission" "allow_cloudwatch_to_call" {
  statement_id = "${var.stack_prefix}_AllowExecutionFromCloudWatch_${var.unique_name}"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.ebs_bckup_lambda.function_name}"
  principal = "events.amazonaws.com"
  source_arn = "${aws_cloudwatch_event_rule.ebs_bckup_timer.arn}"
}
