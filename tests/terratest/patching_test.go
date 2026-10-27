// patching_test.go
// Terratest suite for terraform-ws2025-patching
//
// Test IDs covered:
//   TC-TF-001  Terraform init succeeds
//   TC-TF-002  Terraform validate passes
//   TC-TF-003  Terraform plan produces no errors
//   TC-TF-004  AMI data source resolves a Windows Server 2025 AMI
//   TC-TF-005  Security group restricts WinRM to allowed_cidr_blocks
//   TC-TF-006  Root EBS volume is encrypted
//   TC-TF-007  admin_password validation rejects weak passwords
//   TC-TF-008  admin_password validation accepts strong passwords
//   TC-TF-009  null provider is declared (WARN-02 regression)
//   TC-TF-010  Instance type default is t3.medium
//
// Run:
//   cd tests/terratest
//   go test -v -timeout 30m -run TestPatching
//
// Requirements:
//   - AWS credentials in environment (or IAM role)
//   - TF_VAR_vpc_id, TF_VAR_subnet_id, TF_VAR_admin_password set
//   - Go 1.21+, Terraform 1.6+

package test

import (
	"os"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// sharedTerraformOptions builds options shared across tests.
func sharedTerraformOptions(t *testing.T) *terraform.Options {
	t.Helper()
	return &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"vpc_id":         requireEnv(t, "TF_VAR_vpc_id"),
			"subnet_id":      requireEnv(t, "TF_VAR_subnet_id"),
			"admin_password": requireEnv(t, "TF_VAR_admin_password"),
			"aws_region":     getEnvOrDefault("TF_VAR_aws_region", "us-east-1"),
		},
		NoColor: true,
	}
}

func requireEnv(t *testing.T, key string) string {
	t.Helper()
	v := os.Getenv(key)
	require.NotEmpty(t, v, "Required env var %q is not set", key)
	return v
}

func getEnvOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// TC-TF-001: terraform init must succeed
func TestTerraformInit(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	_, err := terraform.InitE(t, opts)
	assert.NoError(t, err, "TC-TF-001: terraform init should succeed")
}

// TC-TF-002: terraform validate must pass
func TestTerraformValidate(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	output, err := terraform.RunTerraformCommandE(t, opts, "validate")
	assert.NoError(t, err, "TC-TF-002: terraform validate should pass")
	assert.Contains(t, output, "Success", "TC-TF-002: validate output should contain 'Success'")
}

// TC-TF-003: terraform plan must produce no errors
func TestTerraformPlanNoErrors(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	_, err := terraform.PlanE(t, opts)
	assert.NoError(t, err, "TC-TF-003: terraform plan should produce no errors")
}

// TC-TF-004: AMI data source must resolve a WS2025 AMI name
func TestAMINameContainsWS2025(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	terraform.Plan(t, opts)
	amiName := terraform.Output(t, opts, "ami_name_used")
	assert.Contains(
		t, strings.ToLower(amiName), "2025",
		"TC-TF-004: resolved AMI name should contain '2025'",
	)
}

// TC-TF-005: Security group must NOT allow 0.0.0.0/0 on WinRM ports
func TestSecurityGroupNotOpenToWorld(t *testing.T) {
	t.Parallel()
	opts := &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"vpc_id":              requireEnv(t, "TF_VAR_vpc_id"),
			"subnet_id":           requireEnv(t, "TF_VAR_subnet_id"),
			"admin_password":      requireEnv(t, "TF_VAR_admin_password"),
			"allowed_cidr_blocks": []string{"10.0.0.0/8"},
		},
		NoColor: true,
	}
	terraform.Init(t, opts)
	planOut := terraform.InitAndPlanAndShow(t, opts)
	assert.NotContains(
		t, planOut, "\"0.0.0.0/0\"",
		"TC-TF-005: WinRM security group must not allow 0.0.0.0/0",
	)
}

// TC-TF-006: Root EBS volume must be encrypted
func TestEBSEncrypted(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	planJSON := terraform.InitAndPlanAndShowWithStruct(t, opts)
	for _, rc := range planJSON.ResourceChanges {
		if rc.Type == "aws_instance" {
			afterValues := rc.Change.After.(map[string]interface{})
			if rbd, ok := afterValues["root_block_device"]; ok {
				for _, disk := range rbd.([]interface{}) {
					d := disk.(map[string]interface{})
					assert.Equal(t, true, d["encrypted"],
						"TC-TF-006: root EBS volume must have encrypted=true")
				}
			}
		}
	}
}

// TC-TF-007: Weak admin_password must be rejected by validation
func TestWeakPasswordRejected(t *testing.T) {
	t.Parallel()
	opts := &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"vpc_id":         requireEnv(t, "TF_VAR_vpc_id"),
			"subnet_id":      requireEnv(t, "TF_VAR_subnet_id"),
			"admin_password": "short",
		},
		NoColor: true,
	}
	terraform.Init(t, opts)
	_, err := terraform.PlanE(t, opts)
	assert.Error(t, err, "TC-TF-007: weak admin_password should cause plan to fail")
	if err != nil {
		assert.Contains(t, err.Error(), "admin_password",
			"TC-TF-007: error message should mention admin_password")
	}
}

// TC-TF-008: Strong admin_password must be accepted
func TestStrongPasswordAccepted(t *testing.T) {
	t.Parallel()
	opts := &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"vpc_id":         requireEnv(t, "TF_VAR_vpc_id"),
			"subnet_id":      requireEnv(t, "TF_VAR_subnet_id"),
			"admin_password": "Str0ng#P@ssw0rd!",
		},
		NoColor: true,
	}
	terraform.Init(t, opts)
	_, err := terraform.PlanE(t, opts)
	assert.NoError(t, err, "TC-TF-008: strong admin_password should be accepted")
}

// TC-TF-009: null provider must be declared (WARN-02 regression guard)
func TestNullProviderDeclared(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	output, err := terraform.RunTerraformCommandE(t, opts, "providers")
	require.NoError(t, err, "TC-TF-009: terraform providers should not error")
	assert.Contains(t, output, "hashicorp/null",
		"TC-TF-009: null provider must be declared in required_providers")
}

// TC-TF-010: Default instance type must be t3.medium
func TestDefaultInstanceType(t *testing.T) {
	t.Parallel()
	opts := sharedTerraformOptions(t)
	terraform.Init(t, opts)
	planJSON := terraform.InitAndPlanAndShowWithStruct(t, opts)
	for _, rc := range planJSON.ResourceChanges {
		if rc.Type == "aws_instance" {
			afterValues := rc.Change.After.(map[string]interface{})
			assert.Equal(t, "t3.medium", afterValues["instance_type"],
				"TC-TF-010: default instance_type should be t3.medium")
		}
	}
}
