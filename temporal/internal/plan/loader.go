package plan

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"

	"temporal-orchestration/internal/workflows"
)

type templateImport struct {
	Templates map[string]workflows.PipelineStep `yaml:"templates"`
}

// Load reads a YAML pipeline plan from planPath, resolves template imports,
// and returns the fully-merged PipelineInput ready for validation.
func Load(planPath string) (workflows.PipelineInput, error) {
	data, err := os.ReadFile(planPath)
	if err != nil {
		return workflows.PipelineInput{}, fmt.Errorf("unable to read plan file: %w", err)
	}

	var input workflows.PipelineInput
	if err := decodeYAMLStrict(data, &input); err != nil {
		return workflows.PipelineInput{}, fmt.Errorf("unable to parse plan: %w", err)
	}

	if len(input.Imports) > 0 {
		if input.Templates == nil {
			input.Templates = map[string]workflows.PipelineStep{}
		}
		for _, importPath := range input.Imports {
			resolvedPath := importPath
			if !filepath.IsAbs(resolvedPath) {
				resolvedPath = filepath.Join(filepath.Dir(planPath), importPath)
			}
			importTemplates, err := loadTemplateImport(resolvedPath)
			if err != nil {
				return workflows.PipelineInput{}, err
			}
			for name, tmpl := range importTemplates {
				if _, exists := input.Templates[name]; exists {
					return workflows.PipelineInput{}, fmt.Errorf("duplicate template name %q from import %q", name, importPath)
				}
				input.Templates[name] = tmpl
			}
		}
	}

	resolvedSteps, err := resolveStepTemplates(input.Steps, input.Templates)
	if err != nil {
		return workflows.PipelineInput{}, err
	}
	input.Steps = resolvedSteps

	if input.Params == nil {
		input.Params = map[string]string{}
	}
	if input.Env == nil {
		input.Env = map[string]string{}
	}
	return input, nil
}

func decodeYAMLStrict(data []byte, target any) error {
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(target); err != nil {
		return err
	}
	return nil
}

func loadTemplateImport(path string) (map[string]workflows.PipelineStep, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("unable to read import file %q: %w", path, err)
	}

	var imported templateImport
	if err := decodeYAMLStrict(data, &imported); err != nil {
		return nil, fmt.Errorf("unable to parse import file %q: %w", path, err)
	}
	if len(imported.Templates) == 0 {
		return nil, fmt.Errorf("import file %q has no templates", path)
	}
	return imported.Templates, nil
}

func resolveStepTemplates(steps []workflows.PipelineStep, templates map[string]workflows.PipelineStep) ([]workflows.PipelineStep, error) {
	if len(steps) == 0 {
		return nil, nil
	}
	resolved := make([]workflows.PipelineStep, 0, len(steps))
	for _, step := range steps {
		if step.Template == "" {
			resolved = append(resolved, step)
			continue
		}
		templateStep, ok := templates[step.Template]
		if !ok {
			return nil, fmt.Errorf("step %q references unknown template %q", step.ID, step.Template)
		}
		if templateStep.Template != "" {
			return nil, fmt.Errorf("template %q may not reference another template", step.Template)
		}
		merged := MergeStep(templateStep, step)
		merged.Template = ""
		resolved = append(resolved, merged)
	}
	return resolved, nil
}
