use ruby_prism::{ClassNode, DefNode, Location, ModuleNode, Visit};

use super::{Method, Source, Span};

#[cfg(test)]
mod tests;

/// `None` when the source does not parse.
#[must_use]
pub fn static_methods(source: &Source) -> Option<Vec<Method>> {
    let result = ruby_prism::parse(source.bytes());
    if result.errors().next().is_some() {
        return None;
    }
    let mut collector = Collector { source, owners: Vec::new(), methods: Vec::new() };
    collector.visit(&result.node());
    Some(collector.methods)
}

struct Collector<'s> {
    source: &'s Source,
    owners: Vec<String>,
    methods: Vec<Method>,
}

impl Collector<'_> {
    fn within(&mut self, owner: &Location<'_>, visit: impl FnOnce(&mut Self)) {
        self.owners.push(String::from_utf8_lossy(owner.as_slice()).into_owned());
        visit(self);
        self.owners.pop();
    }

    fn span(&self, location: &Location<'_>) -> Span {
        let (start_line, start_column) = self.source.position(location.start_offset());
        let (end_line, end_column) = self.source.position(location.end_offset());
        Span { start_line, start_column, end_line, end_column }
    }
}

impl<'pr> Visit<'pr> for Collector<'_> {
    fn visit_class_node(&mut self, node: &ClassNode<'pr>) {
        self.within(&node.constant_path().location(), |collector| {
            ruby_prism::visit_class_node(collector, node);
        });
    }

    fn visit_module_node(&mut self, node: &ModuleNode<'pr>) {
        self.within(&node.constant_path().location(), |collector| {
            ruby_prism::visit_module_node(collector, node);
        });
    }

    fn visit_def_node(&mut self, node: &DefNode<'pr>) {
        self.methods.push(Method {
            owner: self.owners.last().map_or("Object", String::as_str).to_owned(),
            name: String::from_utf8_lossy(node.name().as_slice()).into_owned(),
            span: self.span(&node.location()),
            hits: 0,
        });
        ruby_prism::visit_def_node(self, node);
    }
}
